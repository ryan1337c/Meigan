"""Export YOLOE-26n as a detection-only Core ML model for Identify mode.

Two vocabularies are supported:
  text         (default) the class list in household_classes.txt, embedded with MobileCLIP2 and baked into the model
  prompt-free  the built-in ~4.6k-class vocabulary of the prompt-free checkpoint

Ultralytics only publishes YOLOE-26 as segmentation checkpoints. This script rebuilds the model on the
detection-only config, which drops the mask branch, verifies that every weight used for inference transferred and
that detections match the original, then writes the Core ML package and the class-name list into Meigan/Models.

Usage (from the repo root):
    python3 -m venv ml/.venv && ml/.venv/bin/pip install -r ml/requirements.txt
    ml/.venv/bin/python ml/export_yoloe26n.py
    ml/.venv/bin/python ml/export_yoloe26n.py --vocabulary prompt-free
    ml/.venv/bin/python ml/export_yoloe26n.py --keep-mask-branch  # fallback if verification fails
"""

import argparse
import json
import os
import shutil
import sys
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

import coremltools as ct
import cv2
import torch
from torch import nn
from ultralytics import YOLOE
from ultralytics.data.augment import LetterBox
from ultralytics.utils import ASSETS

SCRIPT_DIR = Path(__file__).resolve().parent
MODELS_DIR = SCRIPT_DIR.parent / "Meigan" / "Models"
TEXT_CLASSES_PATH = SCRIPT_DIR / "household_classes.txt"


@dataclass(frozen=True)
class Vocabulary:
    segmentation_weights: str
    package_path: Path
    names_path: Path
    # Head modules the checkpoint carries but inference never runs, so they are excluded from the weight check.
    unused_modules: tuple[str, ...]


VOCABULARIES = {
    # Text embeddings are computed once at export (reprta) and fused into cv4; visual prompts (savpe) are unused.
    "text": Vocabulary(
        segmentation_weights="yoloe-26n-seg.pt",
        package_path=MODELS_DIR / "yoloe26n_text.mlpackage",
        names_path=MODELS_DIR / "yoloe26n_text_names.json",
        unused_modules=("reprta", "savpe"),
    ),
    # The prompt-free head classifies through its LRPC vocabulary, so the text/visual prompt modules never run.
    "prompt-free": Vocabulary(
        segmentation_weights="yoloe-26n-seg-pf.pt",
        package_path=MODELS_DIR / "yoloe26n_pf.mlpackage",
        names_path=MODELS_DIR / "yoloe26n_pf_names.json",
        unused_modules=("cv4", "one2one_cv4", "reprta", "savpe"),
    ),
}

DETECTION_CONFIG = "yoloe-26n.yaml"
IMAGE_SIZE = 640
INT8_WEIGHTS = 8
MAX_DETECTIONS = 300  # rows in the NMS-free output that IdentifyDetector parses
# coremltools names outputs after internal graph nodes, which change between exports; IdentifyDetector looks this up.
DETECTION_OUTPUT_NAME = "detections"

# Box coordinates are in 640-pixel space, so small float drift is far below a pixel.
OUTPUT_TOLERANCE = 1e-3
DETECTION_COLUMNS = 6  # x1, y1, x2, y2, confidence, class index
PREVIEW_CONFIDENCE = 0.25  # only for the printed label list, not a filter on the export


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--vocabulary", choices=VOCABULARIES, default="text", help="class vocabulary (default: text)")
    parser.add_argument(
        "--keep-mask-branch",
        action="store_true",
        help="export the segmentation checkpoint as-is instead of the detection-only rebuild",
    )
    parser.add_argument("--images", nargs="+", type=Path, help="images for the output check (default: Ultralytics samples)")
    args = parser.parse_args()

    # Ultralytics downloads weights and writes intermediate exports into the working directory.
    os.chdir(SCRIPT_DIR)

    vocabulary = VOCABULARIES[args.vocabulary]
    reference = YOLOE(vocabulary.segmentation_weights)
    is_text = args.vocabulary == "text"

    if is_text:
        names = read_text_classes()
        embeddings = reference.get_text_pe(names)
        reference.set_classes(names, embeddings)
    else:
        names = [reference.names[index] for index in range(len(reference.names))]

    if args.keep_mask_branch:
        model = reference
    else:
        if is_text:
            model = build_text_detection_model(reference, names, embeddings)
        else:
            model = build_prompt_free_detection_model(reference, names)
        verify_weights(model, reference, vocabulary.unused_modules)
        verify_outputs(model, reference, args.images or sorted(ASSETS.glob("*.jpg")))

    write_names(names, vocabulary.names_path)
    export_package(model, vocabulary.package_path)


# MARK: - Build

def read_text_classes() -> list[str]:
    """Read one prompt per line, skipping blank lines and `#` comments; fail on duplicates."""
    lines = (line.strip() for line in TEXT_CLASSES_PATH.read_text().splitlines())
    names = [line for line in lines if line and not line.startswith("#")]
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        sys.exit(f"Duplicate classes in {TEXT_CLASSES_PATH.name}: {duplicates}")
    print(f"Read {len(names)} text prompts from {TEXT_CLASSES_PATH.name}")
    return names


def build_text_detection_model(reference: YOLOE, names: list[str], embeddings: torch.Tensor) -> YOLOE:
    """Load the text-prompt segmentation weights into the detection-only config with the same embeddings.

    The exporter fuses the embeddings into the classification head, so the app never runs a text encoder.
    """
    model = YOLOE(DETECTION_CONFIG)
    model.model.eval().load(reference.model)
    model.set_classes(names, embeddings)
    return model


def build_prompt_free_detection_model(reference: YOLOE, names: list[str]) -> YOLOE:
    """Recreate the prompt-free head layout on the detection-only config, then load the segmentation weights.

    The published checkpoint is fused: the last classification and box convolutions were moved into LRPC heads.
    A freshly built config has no LRPC heads, so a plain `load` would silently skip the whole vocabulary. Building
    them first with placeholder vocabularies gives every checkpoint tensor a matching key and shape.
    """
    model = YOLOE(DETECTION_CONFIG)
    detection_net = model.model.eval()
    reference_head = reference.model.model[-1]

    detection_net.set_vocab(
        placeholder_vocab(reference_head.lrpc),
        names,
        one2one_vocab=placeholder_vocab(reference_head.one2one_lrpc),
    )
    detection_net.load(reference.model)
    return model


def placeholder_vocab(lrpc_heads: nn.ModuleList) -> nn.ModuleList:
    """Return 1x1 convolutions shaped like the reference vocabulary, which `set_vocab` expects before converting."""
    vocab = nn.ModuleList()
    for head in lrpc_heads:
        out_channels, in_channels = head.vocab.weight.shape[:2]
        vocab.append(nn.Conv2d(in_channels, out_channels, kernel_size=1))
    return vocab


# MARK: - Verification

def verify_weights(model: YOLOE, reference: YOLOE, unused_modules: tuple[str, ...]) -> None:
    """Fail unless every backbone, neck, and head tensor used for inference equals the reference."""
    head_prefix = f"model.{len(model.model.model) - 1}."
    unused_prefixes = tuple(f"{head_prefix}{name}." for name in unused_modules)
    reference_state = reference.model.state_dict()

    required = {key: tensor for key, tensor in model.model.state_dict().items() if not key.startswith(unused_prefixes)}
    missing = [key for key in required if key not in reference_state]
    mismatched = [
        key
        for key in required
        if key in reference_state
        and (required[key].shape != reference_state[key].shape or not torch.equal(required[key], reference_state[key]))
    ]

    print(f"Transferred {len(required) - len(missing) - len(mismatched)}/{len(required)} required tensors")
    if missing or mismatched:
        for key in missing:
            print(f"  missing:    {key}")
        for key in mismatched:
            print(f"  mismatched: {key}")
        sys.exit("Weight transfer failed. Re-run with --keep-mask-branch to export the segmentation model instead.")

    if model.names != reference.names:
        sys.exit("Class names differ from the reference vocabulary.")


@torch.no_grad()
def verify_outputs(model: YOLOE, reference: YOLOE, image_paths: list[Path]) -> None:
    """Fail unless the NMS-free detections match the reference on sample images.

    The segmentation output appends 32 mask coefficients after the detection columns, so only those are compared.
    """
    detection_net = model.model.eval()
    reference_net = reference.model.eval()
    for net in (detection_net, reference_net):
        net.model[-1].end2end = True  # the one-to-one branch the NMS-free export uses
        net.model[-1].max_det = MAX_DETECTIONS  # the checkpoint ships with 1000

    letterbox = LetterBox((IMAGE_SIZE, IMAGE_SIZE), auto=False)
    for path in image_paths:
        image = cv2.imread(str(path))
        if image is None:
            sys.exit(f"Could not read {path}")
        rgb = letterbox(image=image)[..., ::-1].transpose(2, 0, 1).copy()
        batch = torch.from_numpy(rgb).float().unsqueeze(0) / 255

        detections = detection_net(batch)[0]
        reference_detections = reference_net(batch)[0][0][..., :DETECTION_COLUMNS]
        drift = (detections - reference_detections).abs().max().item()

        labels = sorted({model.names[int(row[5])] for row in detections[0] if row[4] >= PREVIEW_CONFIDENCE})
        print(f"{path.name}: max drift {drift:.2e}, labels {labels}")
        if drift > OUTPUT_TOLERANCE:
            sys.exit(f"Detections on {path.name} differ from the reference model.")


# MARK: - Export

def write_names(names: list[str], names_path: Path) -> None:
    names_path.write_text(json.dumps(names, ensure_ascii=False))
    print(f"Wrote {len(names)} class names to {names_path}")


def export_package(model: YOLOE, package_path: Path) -> None:
    with exact_class_indices():
        exported = Path(
            model.export(format="coreml", imgsz=IMAGE_SIZE, nms=False, quantize=INT8_WEIGHTS, max_det=MAX_DETECTIONS)
        )
    if package_path.exists():
        shutil.rmtree(package_path)
    save_with_named_output(exported, package_path)
    shutil.rmtree(exported)
    print(f"Saved Core ML package to {package_path}")


@contextmanager
def exact_class_indices():
    """Keep the class-index column in FP32 while the rest of the network computes in FP16 for the Neural Engine.

    FP16 only represents integers exactly up to 2048, so with 4585 classes an odd index such as 2163 ("person")
    rounds to its neighbor ("humidifier"). Ultralytics exposes no precision hook for INT8 Core ML exports, so this
    supplies one to `ct.convert` for the duration of the export.
    """
    convert = ct.convert

    def convert_with_fp32_class_index(*args, **kwargs):
        kwargs.setdefault("compute_precision", ct.transform.FP16ComputePrecision(op_selector=runs_in_fp16))
        return convert(*args, **kwargs)

    ct.convert = convert_with_fp32_class_index
    try:
        yield
    finally:
        ct.convert = convert


def runs_in_fp16(op) -> bool:
    """Exclude the output concat and the integer-to-float cast of the class index that feeds it."""
    block_outputs = op.enclosing_block.outputs
    if any(output in block_outputs for output in op.outputs):
        return False
    feeds_output = any(child.outputs[0] in block_outputs for output in op.outputs for child in output.child_ops)
    return not (op.op_type == "cast" and feeds_output)


def save_with_named_output(source: Path, destination: Path) -> None:
    """Rename the `[1, 300, columns]` output; the mask branch's extra prototype output is 4-dimensional."""
    package = ct.models.MLModel(str(source), skip_model_load=True)
    spec = package.get_spec()
    detection_output = next(output for output in spec.description.output if len(output.type.multiArrayType.shape) == 3)
    ct.utils.rename_feature(spec, detection_output.name, DETECTION_OUTPUT_NAME)
    ct.models.MLModel(spec, weights_dir=package.weights_dir, skip_model_load=True).save(str(destination))


if __name__ == "__main__":
    main()
