open Al
open Ast
open Free
open Al_util
open Printf
open Util
open Source

module Il =
struct
  module Atom = El.Atom
  include Il
  include Ast
  include Print
  include Atom
end

(* Errors *)

let error at msg = Error.error at "prose translation" msg

let error_exp exp typ =
  error exp.at (sprintf "unexpected %s: `%s`" typ (Il.Print.string_of_exp exp))

(* Helpers *)

let check_typ_of_exp (ty: string) (exp: Il.exp) =
  match exp.note.it with
  | Il.VarT (id, []) when id.it = ty -> true
  | _ -> false

let is_state: Il.exp -> bool = check_typ_of_exp "state"
let is_store: Il.exp -> bool = check_typ_of_exp "store"
let is_frame: Il.exp -> bool = check_typ_of_exp "frame"
let is_config: Il.exp -> bool = check_typ_of_exp "config"

let split_config (exp: Il.exp): Il.exp * Il.exp =
  assert(is_config exp);
  match exp.it with
  | Il.CaseE ([[]; [{it = Il.Semicolon; _}]; []], {it = TupE [ e1; e2 ]; _})
  when is_state e1 -> e1, e2
  | _ -> assert(false)

let split_state (exp: Il.exp): Il.exp * Il.exp =
  assert(is_state exp);
  match exp.it with
  | Il.CaseE ([[]; [{it = Il.Semicolon; _}]; []], {it = TupE [ e1; e2 ]; _})
  when is_store e1 && is_frame e2 -> e1, e2
  | _ -> assert(false)

let is_list expr =
  match expr.it with
  | Il.CatE _ | Il.ListE _ -> true
  | _ -> false

let rec to_exp_list' (exp: Il.exp): Il.exp list =
  match exp.it with
  | Il.CatE (exp1, exp2) -> to_exp_list' exp1 @ to_exp_list' exp2
  | Il.ListE exps -> List.map (fun e -> { e with it = Il.ListE [e] }) exps
  | _ -> [ exp ]
let to_exp_list (exp: Il.exp): Il.exp list = to_exp_list' exp |> List.rev

let flatten_rec def =
  match def.it with
  | Il.RecD defs -> defs
  | _ -> [ def ]

let get_params winstr =
  match winstr.it with
  | Il.CaseE (_, { it = Il.TupE exps; _ }) -> exps
  | Il.CaseE (_, exp) -> [ exp ]
  | _ -> error winstr.at
    (sprintf "cannot get params of wasm instruction `%s`" (Il.Print.string_of_exp winstr))

let lhs_of_rgroup rgroup =
  let (lhs, _, _) = (List.hd rgroup).it in
  lhs

let name_of_rule rule =
  match rule.it with
  | Il.RuleD (id, _, _, _, _) ->
    String.split_on_char '-' id.it |> List.hd

let args_of_clause clause =
  match clause.it with
  | Il.DefD (_, args, _, _) -> args

let upper = String.uppercase_ascii
let wrap typ e = e $$ no_region % typ

let hole = Il.TextE "_" |> wrap topT

let contains_ids ids expr =
  ids
  |> IdSet.of_list
  |> IdSet.disjoint (free_expr expr)
  |> not

let insert_nop instrs = match instrs with [] -> [ nopI () ] | _ -> instrs

(* Insert `target` at the innermost if instruction *)
let rec insert_instrs target il =
  match Util.Lib.List.split_last_opt il with
  | Some ([], { it = OtherwiseI il'; _ }) -> [ otherwiseI (il' @ insert_nop target) ]
  | Some (h, { it = IfI (cond, il', []); _ }) ->
    h @ [ ifI (cond, insert_instrs (insert_nop target) il' , []) ]
  | _ -> il @ target

(** Translation *)

(* `Il.iter` -> `iter` *)
let rec translate_iter = function
  | Il.Opt -> Opt
  | Il.List1 -> List1
  | Il.List -> List
  | Il.ListN (e, id_opt) ->
    ListN (translate_exp e, Option.map (fun id -> id.it) id_opt)

(* `Il.exp` -> `expr` *)
and translate_exp exp =
  let at = exp.at in
  let note = exp.note in
  match exp.it with
  | Il.NatE n -> numE n ~at:at ~note:note
  | Il.BoolE b -> boolE b ~at:at ~note:note
  (* List *)
  | Il.LenE inner_exp -> lenE (translate_exp inner_exp) ~at:at ~note:note
  | Il.ListE exps -> listE (List.map translate_exp exps) ~at:at ~note:note
  | Il.IdxE (exp1, exp2) ->
    accE (translate_exp exp1, idxP (translate_exp exp2)) ~at:at ~note:note
  | Il.SliceE (exp1, exp2, exp3) ->
    accE (translate_exp exp1, sliceP (translate_exp exp2, translate_exp exp3)) ~at:at ~note:note
  | Il.CatE (exp1, exp2) -> catE (translate_exp exp1, translate_exp exp2) ~at:at ~note:note
  (* Variable *)
  | Il.VarE id -> varE id.it ~at:at ~note:note
  | Il.SubE ({ it = Il.VarE id; _}, t, _) -> subE (id.it, t) ~at:at ~note:note
  | Il.SubE (inner_exp, _, _) -> translate_exp inner_exp
  | Il.IterE (inner_exp, (iter, ids)) ->
    let names = List.map (fun (id, _) -> id.it) ids in
    iterE (translate_exp inner_exp, names, translate_iter iter) ~at:at ~note:note
  (* property access *)
  | Il.DotE (inner_exp, ({it = Atom _; _} as atom)) ->
    accE (translate_exp inner_exp, dotP atom) ~at:at ~note:note
  (* conacatenation of records *)
  | Il.CompE (inner_exp, { it = Il.StrE expfields; _ }) ->
    (* assumption: CompE is only used with at least one literal *)
    let nonempty e = (match e.it with ListE [] | OptE None -> false | _ -> true) in
    List.fold_left
      (fun acc extend_exp ->
        match extend_exp with
        | {it = Il.Atom _; _} as atom, fieldexp ->
          let extend_expr = translate_exp fieldexp in
          if nonempty extend_expr then
            extE (acc, [ dotP atom ], extend_expr, Back) ~at:at ~note:note
          else
            acc
        | _ -> error_exp exp "AL record expression"
      )
      (translate_exp inner_exp) expfields
  | Il.CompE ({ it = Il.StrE expfields; _ }, inner_exp) ->
    (* assumption: CompE is only used with at least one literal *)
    let nonempty e = (match e.it with ListE [] | OptE None -> false | _ -> true) in
    List.fold_left
      (fun acc extend_exp ->
        match extend_exp with
        | {it = Il.Atom _; _} as atom, fieldexp ->
          let extend_expr = translate_exp fieldexp in
          if nonempty extend_expr then
            extE (acc, [ dotP atom ], extend_expr, Front) ~at:at ~note:note
          else
            acc
        | _ -> error_exp exp "AL record expression"
      )
      (translate_exp inner_exp) expfields
  (* extension of record field *)
  | Il.ExtE (base, path, v) -> extE (translate_exp base, translate_path path, translate_exp v, Back) ~at:at ~note:note
  (* update of record field *)
  | Il.UpdE (base, path, v) -> updE (translate_exp base, translate_path path, translate_exp v) ~at:at ~note:note
  (* Binary / Unary operation *)
  | Il.UnE (op, exp) ->
    let exp' = translate_exp exp in
    let op = match op with
    | Il.NotOp -> NotOp
    | Il.MinusOp _ -> MinusOp
    | _ -> error_exp exp "AL unary expression"
    in
    unE (op, exp') ~at:at ~note:note
  | Il.BinE (op, exp1, exp2) ->
    let lhs = translate_exp exp1 in
    let rhs = translate_exp exp2 in
    let op =
      match op with
      | Il.AddOp _ -> AddOp
      | Il.SubOp _ -> SubOp
      | Il.MulOp _ -> MulOp
      | Il.DivOp _ -> DivOp
      | Il.ModOp _ -> ModOp
      | Il.ExpOp _ -> ExpOp
      | Il.AndOp -> AndOp
      | Il.OrOp -> OrOp
      | Il.ImplOp -> ImplOp
      | Il.EquivOp -> EquivOp
    in
    binE (op, lhs, rhs) ~at:at ~note:note
  | Il.CmpE (op, exp1, exp2) ->
    let lhs = translate_exp exp1 in
    let rhs = translate_exp exp2 in
    let compare_op =
      match op with
      | Il.EqOp -> EqOp
      | Il.NeOp -> NeOp
      | Il.LtOp _ -> LtOp
      | Il.GtOp _ -> GtOp
      | Il.LeOp _ -> LeOp
      | Il.GeOp _ -> GeOp
    in
    binE (compare_op, lhs, rhs) ~at:at ~note:note
  (* Set operation *)
  | Il.MemE (exp1, exp2) ->
    let lhs = translate_exp exp1 in
    let rhs = translate_exp exp2 in
    memE (lhs, rhs) ~at:at ~note:note
  (* Tuple *)
  | Il.TupE [e] -> translate_exp e
  | Il.TupE exps -> tupE (List.map translate_exp exps) ~at:at ~note:note
  (* Call *)
  | Il.CallE (id, args) -> callE (id.it, translate_args args) ~at:at ~note:note
  (* Record expression *)
  | Il.StrE expfields ->
    let f acc = function
      | {it = Il.Atom _; _} as atom, fieldexp ->
        let expr = translate_exp fieldexp in
        Record.add atom expr acc
      | _ -> error_exp exp "AL record expression"
    in
    let record = List.fold_left f Record.empty expfields in
    strE record ~at:at ~note:note
  (* CaseE *)
  | Il.CaseE (op, e) -> (
    let exps =
      match e.it with
      | TupE exps -> exps
      | _ -> [ e ]
    in
    match (op, exps) with
    (* Constructor *)
    (* TODO: Need a better way to convert these CaseE into ConstructE *)
    (* TODO: type *)
    | [ [{it = Il.LBrack; _}]; [{it = Il.Dot2; _}]; [{it = Il.RBrack; _}] ], [ e1; e2 ] ->
      tupE [ translate_exp e1; translate_exp e2 ] ~at:at ~note:note
    | [ []; [] ], [ e1 ] -> translate_exp e1
    | [ []; []; [] ], [ e1; e2 ] ->
      tupE [ translate_exp e1; translate_exp e2 ] ~at:at ~note:note
    | [ []; [{it = Il.Semicolon; _}]; [] ], [ e1; e2 ] ->
      tupE [ translate_exp e1; translate_exp e2 ] ~at:at ~note:note
    | _, _ when List.length op = List.length exps + 1 ->
      caseE (op, translate_argexp e) ~at:at ~note:note
    | _ -> yetE (Il.Print.string_of_exp exp) ~at:at ~note:note
    )
  | Il.UncaseE (e, op) ->
    (match op with
    | [ []; [] ] -> translate_exp e
    | _ -> yetE (Il.Print.string_of_exp exp) ~at:at ~note:note
    )
  | Il.ProjE (e, 0) -> translate_exp e
  | Il.OptE inner_exp -> optE (Option.map translate_exp inner_exp) ~at:at ~note:note
  | Il.TheE e -> (
    match note.it with
    | Il.IterT (typ, _) -> chooseE (translate_exp e)  ~at:at ~note:typ
    | _ -> error_exp exp "TheE"
  )
  (* Yet *)
  | _ -> yetE (Il.Print.string_of_exp exp) ~at:at ~note:note

(* `Il.exp` -> `expr list` *)
and translate_argexp exp =
  match exp.it with
  | Il.TupE el -> List.map translate_exp el
  | _ -> [ translate_exp exp ]

(* `Il.arg list` -> `expr list` *)
and translate_args args = List.concat_map ( fun arg ->
  match arg.it with
  | Il.ExpA e -> [ ExpA (translate_exp e) $ arg.at ]
  | Il.TypA typ -> [ TypA typ $ arg.at ]
  | Il.DefA _ -> [] (* TODO: handle functions *)
  | Il.GramA _ -> [] ) args

(* `Il.path` -> `path list` *)
and translate_path path =
  let rec translate_path' path =
    let at = path.at in
    match path.it with
    | Il.RootP -> []
    | Il.IdxP (p, e) -> (translate_path' p) @ [ idxP (translate_exp e) ~at:at ]
    | Il.SliceP (p, e1, e2) -> (translate_path' p) @ [ sliceP (translate_exp e1, translate_exp e2) ~at:at ]
    | Il.DotP (p, ({it = Atom _; _} as atom)) ->
      (translate_path' p) @ [ dotP atom ~at:at ]
    | _ -> assert false
  in
  translate_path' path

let insert_assert exp =
  let at = exp.at in
  match exp.it with
  | Il.CaseE ([{it = Il.Atom "FRAME_"; _}]::_, _) ->
    assertI (topFrameE () ~note:boolT) ~at:at
  | Il.IterE (_, (Il.ListN (e, None), _)) ->
    assertI (topValuesE (translate_exp e) ~at:at ~note:boolT) ~at:at
  | Il.CaseE ([{it = Il.Atom "LABEL_"; _}]::_, { it = Il.TupE [ _n; _instrs; _vals ]; _ }) ->
    assertI (topLabelE () ~at:at ~note:boolT) ~at:at
  | Il.CaseE ([{it = Il.Atom "CONST"; _}]::_, { it = Il.TupE (ty' :: _); _ }) ->
    assertI (topValueE (Some (translate_exp ty')) ~note:boolT) ~at:at
  | _ ->
    assertI (topValueE None ~note:boolT) ~at:at

let assert_cond_of_pop_value e =
  let at = e.at in
  let bt = boolT in
  match e.it with
  | CaseE (op, [t; _]) ->
    (match get_atom op with
    | Some {it = Il.Atom "CONST"; _} -> topValueE (Some t) ~note:bt
    | Some {it = Il.Atom "VCONST"; _} -> topValueE (Some t) ~note:bt
    | _ -> topValueE None ~note:bt
    )
  | GetCurFrameE ->
    topFrameE () ~at:at ~note:bt
  | GetCurLabelE ->
    topLabelE () ~at:at ~note:bt
  (* TODO: Remove this when pops is done *)
  | IterE (_, _, ListN (e', _)) ->
    topValuesE e' ~at:at ~note:bt
  | _ ->
    topValueE None ~note:bt

let assert_of_pop i =
  let at = i.at in
  (* let bt = boolT () in *)

  match i.it with
  | PopI e -> [ assertI (assert_cond_of_pop_value e) ~at:at ]
  (* | PopsI (_, e') -> [ assertI (topValuesE e' ~at:at ~note:bt) ~at:at ] *)
  | _ -> []

let post_process_of_pop i =
  (* HARDCODE : Change ($lunpack(t).CONST c) into (nt.CONST c) *)
  let prefix, pi =
    (match i.it with
    | PopI const ->
      (match const.it with
      | CaseE (op, [ { it = CallE _; _ } as t; c]) ->
        (match (get_atom op) with
        | Some a ->
          let name = Il.Atom.name a in
          let var = if name = "CONST" then "nt_0" else "vt_0" in
          let t' = { t with it = VarE var } in
          let const' = { const with it = CaseE (op, [t'; c]) } in
          let i' = { i with it = PopI const' } in
          [ letI (t', t) ], i'
        | None -> [], i)
      | _ -> [], i)
    | _ -> [], i)
  in
  (* End of HARDCODE *)

  prefix @ assert_of_pop pi @ [pi]

let insert_pop e =
  let valsT = listT valT in
  let pop =
    match e.it with
    | Il.ListE [e'] ->
      popI { (translate_exp e') with note = valT } ~at:e'.at
    | Il.ListE es ->
      popsI { (translate_exp e) with note = valsT } (Some (es |> List.length |> Z.of_int |> numE)) ~at:e.at
    | Il.IterE (_, (Il.ListN (e', None), _)) ->
      popsI { (translate_exp e) with note = valsT } (Some (translate_exp e')) ~at:e.at
    | _ ->
      popsI { (translate_exp e) with note = valsT } None ~at:e.at
  in
  post_process_of_pop pop

(* Assume that only the iter variable is unbound *)
let is_unbound vars e =
  match e.it with
  | Il.IterE (_, (ListN (e', _), _))
    when not (Il.Free.subset (Il.Free.free_exp e') vars) -> true
  | _ -> false

let get_unbound e =
  match e.it with
  | Il.IterE (_, (ListN ({ it = VarE id; _ }, _), _)) -> id.it
  | _ -> error e.at
    (sprintf "cannot get_unbound: not an iter expression `%s`" (Il.Print.string_of_exp e))


let rec translate_rhs exp =
  let at = exp.at in
  let note = exp.note in
  match exp.it with
  (* Trap *)
  | Il.CaseE ([{it = Atom "TRAP"; _}]::_, _) -> [ trapI () ~at:at ]
  (* Context *)
  | Il.CaseE (
      [ { it = Il.Atom "FRAME_"; _ } as atom ] :: _,
      { it =
        Il.TupE [
          { it = Il.VarE arity; note = n1; _ };
          { it = Il.VarE fid; note = n2; _ };
          { it = Il.ListE [ le ]; _ };
        ];
        _;
      }
    ) ->
      let exp1 = varE arity.it ~note:n1 in
      let exp2 = varE fid.it ~note:n2 in
      let exp3 = caseE ([[atom]], []) ~note:note in
      let note' = listT note in
    [
      letI (varE "F" ~note:callframeT, frameE (Some (exp1), exp2) ~note:callframeT) ~at:at;
      enterI (varE "F" ~note:callframeT, listE ([exp3]) ~note:note', translate_rhs le) ~at:at;
    ]
  | Il.CaseE (
      [ { it = Atom "LABEL_"; _ } as atom ] :: _,
      { it = Il.TupE [ arity; e1; e2 ]; _ }
    ) ->
    (
    let at' = e2.at in
    let note' = e2.note in
    let exp' = labelE (translate_exp arity, translate_exp e1) ~at:at ~note:labelT in
    let exp'' = listE ([caseE ([[atom]], []) ~note:note]) ~at:at' ~note:note' in
    match e2.it with
    | Il.CatE (ve, ie) ->
      [
        letI (varE "L" ~note:labelT, exp') ~at:at;
        enterI (varE "L" ~note:labelT, catE (translate_exp ie, exp'') ~note:note', [pushI (translate_exp ve)]) ~at:at';
      ]
    | _ ->
      [
        letI (varE "L" ~note:labelT, exp') ~at:at;
        enterI (varE "L" ~note:labelT, catE(translate_exp e2, exp'') ~note:note', []) ~at:at';
      ]
    )
  (* Config *)
  | _ when is_config exp ->
    let state, rhs = split_config exp in
    (match state.it with
    | Il.CallE (f, ae) ->
      translate_rhs rhs @ [ performI (f.it, translate_args ae) ~at:state.at ]
    | _ -> translate_rhs rhs
    )
  (* Recursive case *)
  | Il.SubE (inner_exp, _, _) -> translate_rhs inner_exp
  | Il.CatE (e1, e2) -> translate_rhs e1 @ translate_rhs e2
  | Il.ListE es -> List.concat_map translate_rhs es
  | Il.IterE (inner_exp, (Opt, _itl)) ->
    (* NOTE: Assume that no other iter is nested for Opt *)
    (* TODO: better name using type *)
    let tmp_name = Il.VarE ("instr_0" $ no_region) $$ no_region % inner_exp.note in
    [ ifI (
      isDefinedE (translate_exp exp) ~note:boolT,
      letI (OptE (Some (translate_exp tmp_name)) $$ exp.at % exp.note, translate_exp exp) ~at:at :: translate_rhs tmp_name,
      []
    ) ~at:at ]
  | Il.IterE (inner_exp, (iter, itl)) ->
    let iter_ids = itl |> List.map fst |> List.map it in
    let walk_expr _walker (expr: expr): expr =
      let typ = Il.IterT (expr.note, Il.List) $ no_region in
      IterE (expr, iter_ids, translate_iter iter) $$ exp.at % typ
    in
    let walker = { Walk.base_walker with walk_expr } in

    let instrs = translate_rhs inner_exp in
    List.map (walker.walk_instr walker) instrs
  (* Value *)
  | _ when Valid.sub_typ exp.note valT -> [ pushI (translate_exp exp) ]
  | Il.CaseE ([{it = Atom id; _}]::_, _) when List.mem id [
      (* TODO: Consider automating this *)
      "CONST";
      "VCONST";
      "REF.I31_NUM";
      "REF.STRUCT_ADDR";
      "REF.ARRAY_ADDR";
      "REF.FUNC_ADDR";
      "REF.HOST_ADDR";
      "REF.EXTERN";
      "REF.NULL"
  ] -> [ pushI { (translate_exp exp) with note=valT } ~at:at ]
  (* TODO: use hint *)
  | Il.CallE (id, _) when id.it = "const" ->
    [ pushI { (translate_exp exp) with note=valT } ~at:at ]
  (* Instr *)
  (* TODO: use hint *)
  | _ when Valid.sub_typ exp.note instrT || Valid.sub_typ exp.note admininstrT ->
    [ executeI (translate_exp exp) ]
  | _ -> error_exp exp "expression on rhs of reduction"


(* Handle pattern matching *)

let lhs_id_ref = ref 0
(* let lhs_prefix = "y_" *)
let init_lhs_id () = lhs_id_ref := 0
let get_lhs_name e =
  let lhs_id = !lhs_id_ref in
  lhs_id_ref := (lhs_id + 1);
  varE (typ_to_var_name e.note ^ "_" ^ string_of_int lhs_id) ~note:e.note


(* Helper functions *)
let rec contains_name e = match e.it with
  | VarE _ | SubE _ -> true
  | IterE (e', _, _) -> contains_name e'
  | _ -> false

let extract_non_names =
  List.fold_left_map (fun acc e ->
    if contains_name e then acc, e
    else
      let fresh = get_lhs_name e in
      [ e, fresh ] @ acc, fresh
  ) []

let contains_diff target_ns e =
  let free_ns = free_expr e in
  not (IdSet.is_empty free_ns) && IdSet.disjoint free_ns target_ns

let handle_partial_bindings lhs rhs ids =
  match lhs.it with
  | CallE (_, _) -> lhs, rhs, []
  | _ ->
    let conds = ref [] in
    let target_ns = IdSet.of_list ids in
    let pre_expr = (fun e ->
      if not (contains_diff target_ns e) then
        e
      else (
        let new_e = get_lhs_name e in
        conds := !conds @ [ BinE (EqOp, new_e, e) $$ no_region % boolT ];
        new_e
      )
    ) in
    let walker = Al.Walk.walk_expr { Al.Walk.default_config with
      pre_expr;
      stop_cond_expr = contains_diff target_ns;
    } in
    let new_lhs = walker lhs in
    new_lhs, rhs, List.fold_left (fun il c -> [ ifI (c, il, []) ]) [] !conds

let rec translate_bindings ids bindings =
  List.fold_right (fun (l, r) cont ->
    match l with
    | _ when IdSet.is_empty (free_expr l) ->
      [ ifI (BinE (EqOp, r, l) $$ no_region % boolT, [], []) ]
    | _ -> insert_instrs cont (handle_special_lhs l r ids)
  ) bindings []

and call_lhs_to_inverse_call_rhs lhs rhs free_ids =

  (* Get CallE fields *)

  let f, args =
    match lhs.it with
    | CallE (f, args) -> f, args
    | _ -> assert (false);
  in

  (* Helper functions *)
  let expr2arg e = ExpA e $ e.at in
  let arg2expr a =
    match a.it with
    | ExpA e -> e
    | TypA _ -> error a.at "Cannot translate to inverse function for type argument"
  in
  let contains_free a =
    match a.it with
    | ExpA e -> contains_ids free_ids e
    | TypA _ -> false
  in
  let rhs2args e =
    (match e.it with
    | TupE el -> el
    | _ -> [ e ]
    ) |> List.map expr2arg
  in
  let args2lhs args =
    let es = List.map arg2expr args in
    if List.length es = 1 then
      List.hd es
    else
      let typ = Il.TupT (List.map (fun e -> no_name, e.note) es) $ no_region in
      TupE es $$ no_region % typ
  in

  (* All arguments are free *)

  if List.for_all contains_free args then
    let new_lhs = args2lhs args in
    let indices = List.init (List.length args) Option.some in
    let new_rhs =
      InvCallE (f, indices, rhs2args rhs) $$ lhs.at % new_lhs.note
    in
    new_lhs, new_rhs

  (* Some arguments are free  *)

  else if List.exists contains_free args then
    (* Distinguish free arguments and bound arguments *)
    let free_args_with_index, bound_args =
      args
      |> List.mapi (fun i arg ->
          if contains_free arg then Some (arg, i), None
          else None, Some arg
        )
      |> List.split
    in
    let bound_args = List.filter_map (fun x -> x) bound_args in
    let indices = List.map (Option.map snd) free_args_with_index in
    let free_args =
      free_args_with_index
      |> List.filter_map (Option.map fst)
    in

    (* Free argument become new lhs & InvCallE become new rhs *)
    let new_lhs = args2lhs free_args in
    let new_rhs =
      InvCallE (f, indices, bound_args @ rhs2args rhs) $$ lhs.at % new_lhs.note
    in
    new_lhs, new_rhs

  (* No argument is free *)

  else
    Print.string_of_expr lhs
    |> sprintf "lhs expression %s doesn't contain free variable"
    |> error lhs.at

and handle_call_lhs lhs rhs free_ids =

  (* Helper function *)

  let matches typ1 typ2 = Valid.sub_typ typ1 typ2 || Valid.sub_typ typ2 typ1 in

  (* LHS type and RHS type are the same: normal inverse function *)

  if matches lhs.note rhs.note then
    let new_lhs, new_rhs = call_lhs_to_inverse_call_rhs lhs rhs free_ids in
    handle_special_lhs new_lhs new_rhs free_ids

  (* RHS has more iter: it is in map translation process *)

  else

    let rec get_base_typ_and_iters typ1 typ2 =
      match typ1.it, typ2.it with
      | _, Il.IterT (typ2', iter) when not (matches typ1 typ2) ->
        let base_typ, iters = get_base_typ_and_iters typ1 typ2' in
        base_typ, iter :: iters
      | _, _ when matches typ1 typ2 -> typ2, []
      | _ ->
        error lhs.at
          (sprintf "lhs type %s mismatch with rhs type %s"
            (Il.string_of_typ lhs.note) (Il.string_of_typ rhs.note)
          )
    in

    let base_typ, map_iters =  get_base_typ_and_iters lhs.note rhs.note in
    (* TODO: Better name using type *)
    let var_name = typ_to_var_name base_typ in
    let var_expr = VarE var_name $$ no_region % base_typ in
    let to_iter_expr =
      List.fold_right
        (fun iter e ->
          let iter_typ = Il.IterT (e.note, iter) $ no_region in
          IterE (e, [var_name], translate_iter iter) $$ e.at % iter_typ
        )
        map_iters
    in

    let new_lhs, new_rhs = call_lhs_to_inverse_call_rhs lhs var_expr free_ids in
    (* Introduce new variable for map *)
    let let_instr = letI (to_iter_expr var_expr, rhs) in
    let_instr :: handle_special_lhs new_lhs (to_iter_expr new_rhs) free_ids

and handle_iter_lhs lhs rhs free_ids =

  (* Get IterE fields *)

  let inner_lhs, iter_ids, iter =
    match lhs.it with
    | IterE (inner_lhs, iter_ids, iter) ->
      inner_lhs, iter_ids, iter
    | _ -> assert (false);
  in

  (* Helper functions *)

  let iter_ids_of (expr: expr): string list =
    expr
    |> free_expr
    |> IdSet.inter (IdSet.of_list iter_ids)
    |> IdSet.elements
  in
  let walk_expr (walker: Walk.walker) (expr: expr): expr =
    if contains_ids iter_ids expr then
      let iter', typ =
        match iter with
        | Opt -> iter, Il.IterT (expr.note, Il.Opt) $ no_region
        | ListN (expr', None) when not (contains_ids free_ids expr') ->
          List, Il.IterT (expr.note, Il.List) $ no_region
        | _ -> iter, Il.IterT (expr.note, Il.List) $ no_region
      in
      IterE (expr, iter_ids_of expr, iter') $$ lhs.at % typ
    else
      (Option.get walker.super).walk_expr walker expr
  in

  (* Translate inner lhs *)

  let instrs = handle_special_lhs inner_lhs rhs free_ids in

  (* Iter injection *)

  let walker = { Walk.base_walker with super = Some Walk.base_walker; walk_expr } in
  let instrs' = List.map (walker.walk_instr walker) instrs in

  (* Add ListN condition *)
  match iter with
  | ListN (expr, None) when not (contains_ids free_ids expr) ->
    let at = over_region [ lhs.at; rhs.at ] in
    assertI (BinE (EqOp, lenE rhs ~note:expr.note, expr) $$ at % boolT) :: instrs'
  | _ -> instrs'

and handle_special_lhs lhs rhs free_ids =
  let at = over_region [ lhs.at; rhs.at ] in
  match lhs.it with
  (* Handle inverse function call *)
  | CallE _ -> handle_call_lhs lhs rhs free_ids
  (* Handle iterator *)
  | IterE _ -> handle_iter_lhs lhs rhs free_ids
  (* Handle subtyping *)
  | SubE (s, t) ->
    let rec inject_hasType expr =
      match expr.it with
      | IterE (inner_expr, ids, iter) ->
        IterE (inject_hasType inner_expr, ids, iter) $$ expr.at % boolT
      | _ -> HasTypeE (expr, t) $$ rhs.at % boolT
    in
    [ ifI (
      inject_hasType rhs,
      [ letI (VarE s $$ lhs.at % lhs.note, rhs) ~at:at ],
      []
    )]
  (* Normal cases *)
  | CaseE (op, es) ->
    let tag = get_atom op |> Option.get in
    let bindings, es' = extract_non_names es in
    let rec inject_isCaseOf expr =
      match expr.it with
      | IterE (inner_expr, ids, iter) ->
        IterE (inject_isCaseOf inner_expr, ids, iter) $$ expr.at % boolT
      | _ -> IsCaseOfE (expr, tag) $$ rhs.at % boolT
    in
    (match tag with
    | { it = Il.Atom _; _} ->
      [ ifI (
        inject_isCaseOf rhs,
        letI (caseE (op, es') ~at:lhs.at ~note:lhs.note, rhs) ~at:at
        :: translate_bindings free_ids bindings,
        []
      )]
    | _ ->
      letI (caseE (op, es') ~at:lhs.at ~note:lhs.note, rhs) ~at:at
      :: translate_bindings free_ids bindings)
  | ListE es ->
    let bindings, es' = extract_non_names es in
    if List.length es >= 2 then (* TODO: remove this. This is temporarily for a pure function returning stores *)
      letI (listE es' ~at:lhs.at ~note:lhs.note, rhs) ~at:at :: translate_bindings free_ids bindings
    else
      [
        ifI
          ( binE (EqOp, lenE rhs ~note:natT, numE (Z.of_int (List.length es)) ~note:natT) ~note:boolT,
            letI (listE es' ~at:lhs.at ~note:lhs.note, rhs) ~at:at :: translate_bindings free_ids bindings,
            [] );
      ]
  | OptE None ->
    [
      ifI
        ( unE (NotOp, isDefinedE rhs ~note:boolT) ~note:boolT,
          [],
          [] );
    ]
  | OptE (Some ({ it = VarE _; _ })) ->
    [
      ifI
        ( isDefinedE rhs ~note:boolT,
          [letI (lhs, rhs) ~at:at],
          [] );
     ]
  | OptE (Some e) ->
    let fresh = get_lhs_name e in
    [
      ifI
        ( isDefinedE rhs ~note:boolT,
          letI (optE (Some fresh) ~at:lhs.at ~note:lhs.note, rhs) ~at:at :: handle_special_lhs e fresh free_ids,
          [] );
     ]
  | BinE (AddOp, a, b) ->
    [
      ifI
        ( binE (GeOp, rhs, b) ~note:boolT,
          [letI (a, binE (SubOp, rhs, b) ~at:at ~note:natT) ~at:at],
          [] );
    ]
  | CatE (prefix, suffix) ->
    let handle_list e =
      match e.it with
      | ListE es ->
        let bindings', es' = extract_non_names es in
        Some (numE (Z.of_int (List.length es)) ~note:natT), bindings', listE es' ~note:e.note
      | IterE (({ it = VarE _; _ } | { it = SubE _; _ }), _, ListN (e', None)) ->
        Some e', [], e
      | _ ->
        None, [], e in
    let length_p, bindings_p, prefix' = handle_list prefix in
    let length_s, bindings_s, suffix' = handle_list suffix in
    (* TODO: This condition should be injected by sideconditions pass *)
    let cond = match length_p, length_s with
      | None, None -> yetE ("Nondeterministic assignment target: " ^ Al.Print.string_of_expr lhs) ~note:boolT
      | Some l, None
      | None, Some l -> binE (GeOp, lenE rhs ~note:l.note, l) ~note:boolT
      | Some l1, Some l2 -> binE (EqOp, lenE rhs ~note:l1.note, binE (AddOp, l1, l2) ~note:natT) ~note:boolT
    in
    [
      ifI
        ( cond,
          letI (catE (prefix', suffix') ~at:lhs.at ~note:lhs.note, rhs) ~at:at
            :: translate_bindings free_ids (bindings_p @ bindings_s),
          [] );
    ]
  | _ -> [letI (lhs, rhs) ~at:at]

let translate_letpr lhs rhs free_ids =
  (* Translate *)
  let al_lhs, al_rhs = translate_exp lhs, translate_exp rhs in
  let al_ids = List.map it free_ids in

  (* Handle partial bindings *)
  let al_lhs', al_rhs', cond_instrs = handle_partial_bindings al_lhs al_rhs al_ids in

  (* Construct binding instructions *)
  let instrs = handle_special_lhs al_lhs' al_rhs' al_ids in

  (* Insert conditions *)
  if List.length cond_instrs = 0 then instrs
  else insert_instrs cond_instrs instrs


(* HARDCODE: Translate each RulePr manually based on their names *)
let translate_rulepr id exp =
  let at = id.at in
  let expA e = ExpA e $ e.at in
  match id.it, translate_argexp exp with
  | "Eval_expr", [z; is; z'; vs] ->
    (* Note: State is automatically converted into frame by remove_state *)
    (* Note: Push/pop is automatically inserted by handle_frame *)
    let lhs = tupE [z'; vs] ~at:(over_region [z'.at; vs.at]) ~note:vs.note in
    let rhs = callE ("eval_expr", [ expA z; expA is ]) ~note:vs.note in
    [ letI (lhs, rhs) ~at:at ]
  (* ".*_sub" *)
  | name, [_C; rt1; rt2]
    when String.ends_with ~suffix:"_sub" name ->
    [ ifI (matchE (rt1, rt2) ~at:at ~note:boolT, [], []) ~at:at ]
  (* ".*_ok" *)
  | name, el when String.ends_with ~suffix: "_ok" name ->
    (match el with
    | [_; e; t] | [e; t] -> [ assertI (callE (name, [expA e; expA t]) ~at:at ~note:boolT) ~at:at]
    | _ -> error_exp exp "unrecognized form of argument in rule_ok"
    )
  (* ".*_const" *)
  | name, el
    when String.ends_with ~suffix: "_const" name ->
    [ assertI (callE (name, el |> List.map expA) ~at:at ~note:boolT) ~at:at]
  | _ ->
    print_yet exp.at "translate_rulepr" ("`" ^ Il.Print.string_of_exp exp ^ "`");
    [ yetI ("TODO: translate_rulepr " ^ id.it) ~at:at ]

let rec translate_iterpr pr (iter, ids) =
  let instrs = translate_prem pr in
  let iter', ids' = translate_iter iter, IdSet.of_list (List.map (fun (id, _) -> id.it) ids) in
  let lhs_iter = match iter' with | ListN (e, _) -> ListN (e, None) | _ -> iter' in

  let handle_iter_ty ty =
    match iter' with
    | Opt -> iterT ty Il.Opt
    | List | List1 | ListN _ when ty <> boolT -> listT ty
    | _ -> ty
  in

  let distribute_iter lhs rhs =
    let lhs_ids = IdSet.elements (IdSet.inter (free_expr lhs) ids') in
    let rhs_ids = IdSet.elements (IdSet.inter (free_expr rhs) ids') in
    let ty = handle_iter_ty lhs.note in
    let ty' = handle_iter_ty rhs.note in

    assert (List.length (lhs_ids @ rhs_ids) > 0);
    iterE (lhs, lhs_ids, lhs_iter) ~at:lhs.at ~note:ty, iterE (rhs, rhs_ids, iter') ~at:rhs.at ~note:ty'
  in

  let post_instr i =
    let at = i.at in
    match i.it with
    | LetI (lhs, rhs) -> [ letI (distribute_iter lhs rhs) ~at:at ]
    | IfI (cond, il1, il2) ->
        let cond_ids = IdSet.elements (IdSet.inter (free_expr cond) ids') in
        let ty = handle_iter_ty cond.note in
        [ ifI (iterE (cond, cond_ids, iter') ~at:cond.at ~note:ty, il1, il2) ~at:at ]
    | _ -> [ i ]
  in
  let walk_config = { Al.Walk.default_config with post_instr } in
  Al.Walk.walk_instrs walk_config instrs

and translate_prem prem =
  let at = prem.at in
  match prem.it with
  | Il.IfPr exp -> [ ifI (translate_exp exp, [], []) ~at:at ]
  | Il.ElsePr -> [ otherwiseI [] ~at:at ]
  | Il.LetPr (exp1, exp2, ids) ->
    init_lhs_id ();
    translate_letpr exp1 exp2 ids
  | Il.RulePr (id, _, exp) -> translate_rulepr id exp
  | Il.IterPr (pr, exp) -> translate_iterpr pr exp


(* `premise list` -> `instr list` (return instructions) -> `instr list` *)
let translate_prems =
  List.fold_right (fun prem il -> translate_prem prem |> insert_instrs il)

(* s; f; e -> `expr * expr * instr list` *)
let get_config_return_instrs name exp at =
  assert(is_config exp);
  let state, rhs = split_config exp in
  let store, f = split_state state in

  let config = translate_exp store, translate_exp f, translate_rhs rhs in
  (* HARDCODE: hardcoding required for config returning helper functions *)
  match name with
  | "instantiate" -> Manual.return_instrs_of_instantiate config
  | "invoke" -> Manual.return_instrs_of_invoke config
  | _ ->
    error at
      (sprintf "Helper function that returns config requires hardcoding: %s" name)

let translate_helper_body name clause =
  let Il.DefD (_, _, exp, prems) = clause.it in
  let return_instrs =
    if is_config exp then
      get_config_return_instrs name exp clause.at
    else
      [ returnI (Some (translate_exp exp)) ~at:exp.at ]
  in
  translate_prems prems return_instrs

(* Main translation for helper functions *)
let translate_helper partial_funcs def =
  match def.it with
  | Il.DecD (id, _, _, clauses) when List.length clauses > 0 ->
    let name = id.it in
    let unified_clauses = Il2il.unify_defs clauses in
    let args = List.hd unified_clauses |> args_of_clause in
    let params =
      args
      |> translate_args
      |> List.map
        Walk.(walk_arg { default_config with pre_expr = Transpile.remove_sub })
    in
    let blocks = List.map (translate_helper_body name) unified_clauses in
    let body =
      Transpile.merge_blocks blocks
      (* |> Transpile.insert_frame_binding *)
      |> Transpile.handle_frame params
      |> Walk.(walk_instrs { default_config with pre_expr = Transpile.remove_sub })
      |> Transpile.enhance_readability
      |> (if List.mem id partial_funcs then Fun.id else Transpile.ensure_return)
      |> Transpile.flatten_if in

    Some (FuncA (name, params, body) $ def.at)
  | _ -> None


(* Translating helper functions *)
let translate_helpers il =
  (* Get list of partial functions *)
  let get_partial_func def =
    let is_partial_hint hint = hint.Il.hintid.it = "partial" in
    match def.it with
    | Il.HintD { it = Il.DecH (id, hints); _ } when List.exists is_partial_hint hints ->
      Some (id)
    | _ -> None
  in
  let partial_funcs = List.filter_map get_partial_func il in

  List.filter_map (translate_helper partial_funcs) il


let rec kind_of_context e =
  match e.it with
  | Il.CaseE ([{it = Il.Atom "FRAME_"; _} as atom]::_, _) -> atom
  | Il.CaseE ([{it = Il.Atom "LABEL_"; _} as atom]::_, _) -> atom
  | Il.CaseE ([[]; [{it = Il.Semicolon; _}]; []], e')
  | Il.ListE [ e' ]
  | Il.TupE [_ (* z *); e'] -> kind_of_context e'
  | _ -> error e.at "cannot get a frame or label from lhs of the reduction rule"

let in_same_context (lhs1, _, _) (lhs2, _, _) =
  kind_of_context lhs1 = kind_of_context lhs2

let group_contexts xs =
  List.fold_left (fun acc x ->
    let g1, g2 = List.partition (fun g -> in_same_context (List.hd g).it x.it) acc in
    match g1 with
    | [] -> [ x ] :: acc
    | [ g ] -> (x :: g) :: g2
    | _ -> failwith "group_contexts: duplicate groups"
    ) [] xs |> List.rev

let un_unify (lhs, rhs, prems) =
  let new_lhs, new_prems = List.fold_left (fun (lhs, ps) p ->
    match p.it with
    | Il.LetPr (e1, ({ it = Il.VarE uvar; _} as u), _) when Il2il.is_unified_id uvar.it ->
      let new_lhs = Il2il.transform_expr (fun e2 -> if Il.Eq.eq_exp e2 u then e1 else e2) lhs in
      new_lhs, ps
    | _ -> lhs, ps @ [ p ]
  ) (lhs, []) prems in
  new_lhs, rhs, new_prems

let insert_deferred = function
  | None -> Fun.id
  | Some exp ->
    (* Translate deferred lhs *)
    let deferred_instrs = insert_pop exp in

    (* Find unbound variable *)
    let unbound_variable = get_unbound exp in

    (* Insert the translated instructions right after the binding *)
    let f instr =
      match instr.it with
      | LetI (lhs, _) when free_expr lhs |> IdSet.mem unbound_variable ->
        instr :: deferred_instrs
      | _ -> [ instr ] in

    let walk_config = { Al.Walk.default_config with post_instr = f } in
    Al.Walk.walk_instrs walk_config

(* `reduction` -> `instr list` *)
let translate_reduction deferred reduction =
  let _, rhs, prems = reduction.it in

  (* Translate rhs *)
  translate_rhs rhs
  |> insert_nop
  (* Translate premises *)
  |> translate_prems prems
  (* Translate and insert deferred pop instructions *)
  |> insert_deferred deferred


let insert_pop_winstr vars es = match es with
  | [] -> [], None
  | _ ->
    (* ASSUMPTION: The deferred pop is only possible at the bottom of the stack *)
    let (hs, t) = Util.Lib.List.split_last es in
    if is_unbound vars t then
      List.concat_map insert_pop hs, Some t
    else
      List.concat_map insert_pop es, None

let translate_context_winstr winstr =
  let at = winstr.at in
  match winstr.it with
  (* Frame *)
  | Il.CaseE ([{it = Il.Atom "FRAME_"; _} as atom]::_, args) ->
    (match args.it with
    | Il.TupE [arity; name; inner_exp] ->
      [
        letI (translate_exp name, getCurFrameE () ~note:name.note) ~at:at;
        letI (translate_exp arity, arityE (translate_exp name) ~note:arity.note) ~at:at;
        insert_assert inner_exp;
      ]
      @ insert_pop (inner_exp) @
      [
        insert_assert winstr;
        exitI atom ~at:at
      ]
    | _ -> error_exp args "argument of frame"
    )
  (* Label *)
  | Il.CaseE ([{it = Il.Atom "LABEL_"; _} as atom]::_, { it = Il.TupE [ _n; _instrs; vals ]; _ }) ->
    [
      (* TODO: append Jump instr *)
      popallI ({ (translate_exp vals) with note=(listT valT)}) ~at:at;
      insert_assert winstr;
      exitI atom ~at:at
    ]
  | _ -> []

let translate_context ctx vs =
  let at = ctx.at in
  let ty = listT valT in
  let e_vals = iterE (subE ("val", valT) ~note:valT, [ "val" ], List) ~note:ty in
  let vs = List.rev vs in
  let instr_popall = popallI e_vals in
  let instr_pop_context =
    match ctx.it with
    | Il.CaseE ([{it = Il.Atom "LABEL_"; at=at'; _} as atom]::_, { it = Il.TupE [ n; instrs; _hole ]; _ }) ->
      let label = VarE "L" $$ at' % labelT in
      [
        letI (label, getCurLabelE () ~note:labelT) ~at:at;
        letI (translate_exp n, arityE label ~note:n.note) ~at:at;
        letI (translate_exp instrs, contE label ~note:instrs.note) ~at:at;
        exitI atom ~at:at
      ]
    | Il.CaseE ([{it = Il.Atom "FRAME_"; _} as atom]::_, { it = Il.TupE [ n; f; _hole ]; _ }) ->
      let frame = translate_exp f in
      [
        letI (frame, getCurFrameE () ~note:frameT) ~at:at;
        letI (translate_exp n, arityE frame ~note:n.note) ~at:at;
        exitI atom ~at:at
      ]
    | _ -> [ yetI "TODO: translate_context" ~at:at ]
  in
  let instr_let =
    match vs with
    | v1 :: v2 :: vs ->
        let e1 = translate_exp v1 in
        let e2 = translate_exp v2 in
        let e_vs = catE (e1, e2) ~note:e1.note in
        let e =
          List.fold_left
            (fun e_vs v -> catE (e_vs, translate_exp v) ~note:e_vs.note)
            e_vs vs
        in
        [ letI (e, e_vals) ~at:at ]
    | v :: [] ->
        let e = translate_exp v in
        if Eq.eq_expr e e_vals then []
        else [ letI (e, e_vals) ~at:at ]
    | _ -> []
  in
  instr_popall :: instr_pop_context @ instr_let

let translate_context_rgroup lhss sub_algos inner_params =
  let ty = listT valT in
  let e_vals = iterE (varE "val" ~note:valT, [ "val" ], List) ~note:ty in
  let instr_popall = popallI e_vals in
  let instrs_context =
    List.fold_right2 (fun lhs algo acc ->
      match algo.it with
      | RuleA (_, _, params, body) ->
        (* Assume that each sub-algorithms are produced by translate_context,
           i.e., they will always contain instr_popall as their first instruction. *)
        assert(Eq.eq_instr (List.hd body) instr_popall);
        if Option.is_none !inner_params then inner_params := Some params;
        let e_cond =
          match it (kind_of_context lhs) with
          | Il.Atom.Atom "FRAME_" -> topFrameE () ~note:boolT
          | Il.Atom.Atom "LABEL_" -> topLabelE () ~note:boolT
          | _ -> error lhs.at "the context is neither a frame nor a label"
        in
        [ ifI (e_cond, List.tl body, acc) ]
      | _ -> assert false)
    lhss sub_algos []
  in
  instr_popall :: instrs_context

let rec split_lhs_stack' ?(note : Il.typ option) name stack ctxs instrs =
  let target = upper name in
  match stack with
  | [] ->
    let typ = Option.get note in
    let tag = [[Il.Atom target $$ typ.at % Il.Atom.info "instr"]] in
    let winstr = Il.CaseE (tag, Il.TupE [] |> wrap topT) |> wrap typ in
    ctxs @ [ ([], instrs), None ], winstr
  | hd :: tl ->
    match hd.it with
    | Il.ListE [hd'] ->
      (match hd'.it with
      (* Top of the stack is the target instruction *)
      | Il.CaseE (({it = Il.Atom name'; _}::_)::_, _) when name' = target || name' = target ^ "_"
        -> ctxs @ [ (tl, instrs), None ], hd'
      (* Top of the stack is a context (label, frame, ...) *)
      | Il.CaseE (tag, ({it = Il.TupE args; _} as e)) ->
        let list_arg = List.find is_list args in
        let inner_stack = to_exp_list list_arg in
        let holed_args = List.map (fun x -> if x = list_arg then hole else x) args in
        let ctx = { hd' with it = Il.CaseE (tag, { e with it = Il.TupE holed_args }) } in

        split_lhs_stack' name inner_stack (ctxs @ [ ((tl, instrs), Some ctx) ]) []
      (* Should be unreachable? *)
      | _ ->
        split_lhs_stack' ~note:(hd.note) name tl ctxs (hd :: instrs))
    | _ ->
      split_lhs_stack' ~note:(hd.note) name tl ctxs (hd :: instrs)

let split_lhs_stack name stack = split_lhs_stack' name stack [] []


let rec translate_rgroup' context winstr instr_name rel_id rgroup =
  let inner_params = ref None in
  let instrs =
    match context with
    | [ (vs, []), None ] ->
      let pop_instrs, defer_opt = vs |> insert_pop_winstr (Il.Free.free_exp winstr) in
      let inner_pop_instrs = translate_context_winstr winstr in

      let instrs' =
        match rgroup |> Util.Lib.List.split_last with
        (* Either case: No premise for the last reduction rule *)
        | hds, { it = (_, rhs, []); _ } when List.length hds > 0 ->
          assert (defer_opt = None);
          let blocks = List.map (translate_reduction None) hds in
          let body1 = Transpile.merge_blocks blocks in
          let body2 = translate_rhs rhs |> insert_nop in
          eitherI (body1, body2) |> Transpile.push_either
        (* Normal case *)
        | _ ->
          let blocks = List.map (translate_reduction defer_opt) rgroup in
          Transpile.merge_blocks blocks
      in

      pop_instrs @ inner_pop_instrs @ instrs'
    (* The target instruction is inside a context *)
    | [ ([], []), Some context ; (vs, _is), None ] ->
      let head_instrs = translate_context context vs in
      let body_instrs = List.map (translate_reduction None) rgroup |> List.concat in
      head_instrs @ body_instrs
    (* The target instruction is inside different contexts (i.e. return in both label and frame) *)
    | [ ([], [ _ ]), None ] ->
      (try
      let unified_sub_groups =
        rgroup
        |> List.map (Source.map un_unify)
        |> group_contexts
        |> List.map (fun g -> Il2il.unify_lhs (instr_name, rel_id, g)) in
      if List.length unified_sub_groups = 1 then [ yetI "Translation fail: Infinite recursion" ] else
      let lhss = List.map (fun (_, _, g) -> lhs_of_rgroup g) unified_sub_groups in
      let sub_algos = List.map translate_rgroup unified_sub_groups in
      translate_context_rgroup lhss sub_algos inner_params
      with _ ->
        [ yetI "TODO: It is likely that the value stack of two rules are different" ])
    | _ -> [ yetI "TODO: translate_rgroup" ] in
  !inner_params, instrs


(* Main translation for reduction rules
 * `rgroup` -> `Backend-prose.Algo` *)

and get_lhs_stack (exp: Il.exp): Il.exp list =
  if is_config exp then
    split_config exp |> snd |> to_exp_list
  else to_exp_list exp

and translate_rgroup (instr_name, rel_id, rgroup) =
  let lhs, _, _ = (List.hd rgroup).it in
  (* TODO: Generalize getting current frame *)
  let lhs_stack = get_lhs_stack lhs in
  let context, winstr = split_lhs_stack instr_name lhs_stack in

  let inner_params, instrs = translate_rgroup' context winstr instr_name rel_id rgroup in

  let name =
    match winstr.it with
    | Il.CaseE ((({it = Il.Atom _; _} as atom)::_)::_, _) -> atom
    | _ -> assert false
  in
  let anchor = rel_id.it ^ "/" ^ instr_name in
  let al_params =
    match inner_params with
    | None ->
      if instr_name = "frame" || instr_name = "label" then [] else
      get_params winstr
      |> List.map translate_exp
      |> List.map (fun e -> ExpA e $ e.at)
    | Some params -> params
  in
  (* TODO: refactor transpiles *)
  let al_params' =
    List.map
      Walk.(walk_arg { default_config with pre_expr = Transpile.remove_sub })
      al_params
  in
  let body =
    instrs
    |> Transpile.insert_frame_binding
    |> insert_nop
    |> Walk.(walk_instrs { default_config with pre_expr = Transpile.remove_sub })
    |> Transpile.enhance_readability
    |> Transpile.infer_assert
    |> Transpile.flatten_if
  in

  let at = rgroup
    |> List.map at
    |> over_region in
  RuleA (name, anchor, al_params', body) $ at


let rule_to_tup rule =
  match rule.it with
  | Il.RuleD (_, _, _, exp, prems) ->
    match exp.it with
    | Il.TupE [ lhs; rhs ] -> (lhs, rhs, prems) $ rule.at
    | _ -> error_exp exp "form of reduction rule"


(* group reduction rules that have same name *)
let rec group_rules = function
  | [] -> []
  | h :: t ->
    let (rel_id, rule) = h in
    let name = name_of_rule rule in
    let t1, t2 =
      List.partition (fun (_, rule) -> name_of_rule rule = name) t in
    let rules = rule :: List.map (fun (rel_id', rule') ->
      if rel_id = rel_id' then rule' else
        Util.Error.error rule'.at
        "prose transformation"
        "this reduction rule uses a different relation compared to the previous rules"
    ) t1 in
    let tups = List.map rule_to_tup rules in
    (name, rel_id, tups) :: group_rules t2

(* extract reduction rules for wasm instructions *)
let extract_rules def =
  match def.it with
  | Il.RelD (id, _, _, rules) when List.mem id.it [ "Step"; "Step_read"; "Step_pure" ] ->
    List.filter_map (fun rule ->
      match rule.it with
      | Il.RuleD (id', _, _, _, _) when List.mem id'.it [ "pure"; "read" ] ->
        None
      | _ -> Some (id, rule)
    ) rules
  | _ -> []

(* Translating reduction rules *)
let translate_rules il =
  (* Extract rules *)
  il
  |> List.concat_map extract_rules
  (* Group rules that have the same names *)
  |> group_rules
  (* Unify lhs *)
  |> List.map Il2il.unify_lhs
  (* Translate reduction group into algorithm *)
  |> List.map translate_rgroup

let rec collect_def env def =
  let open Il in
  match def.it with
  | TypD (id, ps, insts) -> Env.bind_typ env id (ps, insts)
  | RelD (id, mixop, t, rules) -> Env.bind_rel env id (mixop, t, rules)
  | DecD (id, ps, t, clauses) ->  Env.bind_def env id (ps, t, clauses)
  | GramD (id, ps, t, prods) -> Env.bind_gram env id (ps, t, prods)
  | RecD ds -> List.fold_left collect_def env ds
  | HintD _ -> env

let initialize_env il =
  Al.Valid.env := List.fold_left collect_def !Al.Valid.env il

(* Entry *)
let translate il =

  initialize_env il;

  let not_translate = ["typing.watsup"] in
  let is_al_target def =
    let f = fun name -> String.ends_with ~suffix:name def.at.left.file in
    match def.it with
    | _ when List.exists f not_translate -> false
    | Il.DecD (id, _, _, _) when id.it = "utf8" -> false
    | _ -> true
  in
  let il' =
    il
    |> Preprocess.preprocess
    |> List.concat_map flatten_rec
    |> List.filter is_al_target
    |> Animate.transform
  in

  let al = (translate_helpers il' @ translate_rules il') in
  List.map Transpile.remove_state al
