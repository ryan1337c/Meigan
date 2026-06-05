import Foundation
import Supabase

let supabase = SupabaseClient(
  supabaseURL: URL(string: "https://ycdpummivylbxpwofxaz.supabase.co")!,
  supabaseKey: "sb_publishable_Gm0Xn24t87e8p0Riohi8Vg_LDnRD7dJ",
  options: SupabaseClientOptions(
    auth: SupabaseClientOptions.AuthOptions(
      emitLocalSessionAsInitialSession: true
    )
  )
)