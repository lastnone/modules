open Reference_interpreter
open Source
open Al

(* Hardcoded Data *)

let to_phrase x = (@@) x no_region
let i32 = I32.of_int_s
let i64 = I64.of_int_s
let f32 = F32.of_float
let f64 = F64.of_float

(* Hardcoded Instas *)

let global_insts: global_inst array = [|
  Values.Num (Values.F32 (f32 1.4));
  Values.Num (Values.F32 (f32 5.2));
  Values.Num (Values.F32 (f32 6.9))
|]

let table_insts: table_inst array = [|
  [|
    Values.Ref (Values.NullRef ExternRefType);
    Values.Ref (Values.NullRef FuncRefType);
    Values.Ref (Values.NullRef FuncRefType)
  |];
  [|
    Values.Ref (Values.NullRef FuncRefType);
    Values.Ref (Values.NullRef ExternRefType);
    Values.Ref (Values.NullRef FuncRefType)
  |];
  [|
    Values.Ref (Values.NullRef FuncRefType);
    Values.Ref (Values.NullRef FuncRefType);
    Values.Ref (Values.NullRef ExternRefType)
  |]
|]

let module_inst: module_inst = {
  globaladdr = [|
    IntV 0; (* global address 0 *)
    IntV 1; (* global address 1 *)
    IntV 2; (* global address 2 *)
  |];
  tableaddr = [|
    IntV 0; (* table address 0 *)
    IntV 1; (* table address 1 *)
    IntV 2; (* table address 2 *)
  |]
}

(* Hardcoded Store *)

let initial_store =
  { global = global_insts; table = table_insts }

(* Hardcoded Frame *)

let initial_frame =
  {
    local = [|
      Values.Num (Values.I32 (i32 3));
      Values.Num (Values.I32 (i32 0));
      Values.Num (Values.I32 (i32 7))
    |];
    module_inst = module_inst
  }

(* Hardcoded Wasm Instructions *)

let binop = "binop", [
  Operators.i32_const (i32 19 |> to_phrase) |> to_phrase;
  Operators.i32_const (i32 27 |> to_phrase) |> to_phrase;
  Operators.i32_add |> to_phrase
], "46"

let testop = "testop", [
  Operators.i32_const (i32 0 |> to_phrase) |> to_phrase;
  Operators.i32_eqz |> to_phrase
], "1"

let relop1 = "relop i32", [
  Operators.i32_const (i32 1 |> to_phrase) |> to_phrase;
  Operators.i32_const (i32 3 |> to_phrase) |> to_phrase;
  Operators.i32_gt_s |> to_phrase
], "0"

let relop2 = "relop f32", [
  Operators.f32_const (f32 1.4142135 |> to_phrase) |> to_phrase;
  Operators.f32_const (f32 3.1415926 |> to_phrase) |> to_phrase;
  Operators.f32_gt |> to_phrase
], "0"

let nop = "nop", [
  Operators.i64_const (i64 0 |> to_phrase) |> to_phrase;
  Operators.nop |> to_phrase
], "0"

let drop = "drop", [
  Operators.f64_const (f64 3.1 |> to_phrase) |> to_phrase;
  Operators.f64_const (f64 5.2 |> to_phrase) |> to_phrase;
  Operators.drop |> to_phrase
], "3.100_000_000_000_000_1"

let select = "select", [
  Operators.f64_const (f64 Float.max_float |> to_phrase) |> to_phrase;
  Operators.ref_null Types.FuncRefType |> to_phrase;
  Operators.i32_const (i32 0 |> to_phrase) |> to_phrase;
  Operators.select None |> to_phrase
], "null"

let local_get = "local_get", [
  Operators.local_get (i32 2 |> to_phrase) |> to_phrase
], "7"

let local_set = "local_set", [
  Operators.local_get (i32 2 |> to_phrase) |> to_phrase;
  Operators.i32_const (i32 1 |> to_phrase) |> to_phrase;
  Operators.i32_add |> to_phrase;
  Operators.local_set (i32 2 |> to_phrase) |> to_phrase;
  Operators.local_get (i32 2 |> to_phrase) |> to_phrase
], "8"

let global_get = "global_get", [
  Operators.global_get (i32 1 |> to_phrase) |> to_phrase
], "5.199_999_809_265_136_7"

let table_get = "table_get", [
  Operators.i32_const (i32 1 |> to_phrase) |> to_phrase;
  Operators.table_get (i32 2 |> to_phrase) |> to_phrase
], "null"

let test_cases = [
  binop; testop; relop1; relop2; nop; drop; select;
  local_get; local_set; global_get; table_get
]
