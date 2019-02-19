open Ppxlib

let _name_from_type_name type_name =
  Printf.sprintf "default%s" @@ Util.suffix_from_type_name type_name

let expr_from_lident ~loc {txt; loc = err_loc} =
  match txt with
  | Lident name ->
    Ast_builder.Default.pexp_ident ~loc {txt = Lident (_name_from_type_name name); loc}
  | Ldot (lident, last) ->
    Ast_builder.Default.pexp_ident ~loc {txt = Ldot (lident, _name_from_type_name last); loc}
  | Lapply _ -> Raise.errorf ~loc:err_loc "unhandled longident"

let rec expr_from_core_type ~loc {ptyp_desc; ptyp_loc; _} =
  match ptyp_desc with
  | Ptyp_constr ({txt = Lident "bool"; _}, _) -> Ok [%expr false]
  | Ptyp_constr ({txt = Lident "int"; _}, _) -> Ok [%expr 0]
  | Ptyp_constr ({txt = Lident "int32" | Ldot (Lident "Int32", "t"); _}, _) -> Ok [%expr 0l]
  | Ptyp_constr ({txt = Lident "int64" | Ldot (Lident "Int64", "t"); _}, _) -> Ok [%expr 0L]
  | Ptyp_constr ({txt = Lident "nativeint" | Ldot (Lident "Nativeint", "t"); _}, _) -> Ok [%expr 0n]
  | Ptyp_constr ({txt = Lident "float" | Ldot (Lident "Float", "t"); _}, _) -> Ok [%expr 0.]
  | Ptyp_constr ({txt = Lident "char" | Ldot (Lident "Char", "t"); _}, _) -> Ok [%expr '\x00']
  | Ptyp_constr ({txt = Lident "string" | Ldot (Lident "String", "t"); _}, _) -> Ok [%expr ""]
  | Ptyp_constr ({txt = Lident "option"; _}, _) -> Ok [%expr None]
  | Ptyp_constr ({txt = Lident "list"; _}, _) -> Ok [%expr []]
  | Ptyp_constr ({txt = Lident "array"; _}, _) -> Ok [%expr [||]]
  | Ptyp_constr (lident, _) -> Ok (expr_from_lident ~loc lident)
  | Ptyp_tuple types ->
    let expr_list = List.map (expr_from_core_type ~loc) types in
    ( match Util.List_.all_ok expr_list with
      | Ok expr_list -> Ok (Ast_builder.Default.pexp_tuple ~loc expr_list)
      | Error _ as err -> err
    )
  | Ptyp_var _ -> Loc_err.as_result ~loc:ptyp_loc ~msg:"can't derive default for unspecified type" 
  | _ -> Loc_err.as_result ~loc:ptyp_loc ~msg:"can't derive default from this type"

let expr_from_core_type_exn ~loc core_type =
  Loc_err.ok_or_raise @@ expr_from_core_type ~loc core_type

module Str = struct
  let value_expr_from_manifest ~ptype_loc ~loc manifest =
    match manifest with
    | None ->
      Raise.Default.errorf
        ~loc:ptype_loc
        "can't derive default for an abstract type without a manifest"
    | Some typ -> expr_from_core_type_exn ~loc typ

  let field_binding ~loc {pld_name; pld_type; _} =
    let open Util.Result_ in
    let lident = {txt = Lident pld_name.txt; loc} in
    expr_from_core_type ~loc pld_type >|= fun expr ->
    (lident, expr)

  let value_expr_from_labels ~loc labels =
    let open Util.Result_ in
    let field_bindings = List.map (field_binding ~loc) labels in
    Util.List_.all_ok field_bindings >|= fun field_bindings ->
    Ast_builder.Default.pexp_record ~loc field_bindings None

  let value_expr_from_labels_exn ~loc labels =
    Loc_err.ok_or_raise @@ value_expr_from_labels ~loc labels

  let value_expr_from_ctr_tuple ~loc types =
    let open Util.Result_ in
    let expr_list = List.map (expr_from_core_type ~loc) types in
    match expr_list with
    | [] -> Ok None
    | [expr] -> expr >|= fun expr -> Some expr
    | _ ->
      Util.List_.all_ok expr_list >|= fun expr_list ->
      Some (Ast_builder.Default.pexp_tuple ~loc expr_list)

  let value_expr_from_ctor ~loc {pcd_name = {txt = ctr_name; _}; pcd_args; _} =
    let open Util.Result_ in
    match pcd_args with
    | Pcstr_record labels ->
      value_expr_from_labels ~loc labels >|= fun record_expr ->
      Util.Expr.ctr ~loc ~ctr_name (Some record_expr)
    | Pcstr_tuple types ->
      value_expr_from_ctr_tuple ~loc types >|= Util.Expr.ctr ~loc ~ctr_name

  let rec value_expr_from_ctors ~has_params ~ptype_loc ~loc ctors =
    match ctors with
    | [] -> Raise.Default.errorf ~loc:ptype_loc "can't derive default for empty variant type"
    | [last] ->
      ( match value_expr_from_ctor ~loc last with
        | Ok expr -> expr
        | Error err ->
          if has_params then
            Raise.Default.errorf ~loc:ptype_loc
              "can't derive default for this variant \
               as all constructors have unspecified type arguments"
          else
            Loc_err.raise_ err
      )
    | ctor::tl ->
      ( match value_expr_from_ctor ~loc ctor with
        | Ok expr -> expr
        | Error _ -> value_expr_from_ctors ~has_params ~ptype_loc ~loc tl
      )

  let value_pat_from_name ~loc type_name =
    let name = _name_from_type_name type_name in
    Ast_builder.Default.ppat_var ~loc {txt = name; loc}

  let from_td ~loc {ptype_name; ptype_kind; ptype_manifest; ptype_loc; ptype_params; _} =
    let has_params = ptype_params <> [] in
    let expr =
      match ptype_kind with
      | Ptype_abstract -> value_expr_from_manifest ~ptype_loc ~loc ptype_manifest
      | Ptype_record labels -> value_expr_from_labels_exn ~loc labels
      | Ptype_variant constructors -> value_expr_from_ctors ~has_params ~ptype_loc ~loc constructors
      | Ptype_open -> Raise.Default.errorf ~loc:ptype_loc "unhandled type kind"
    in
    let pat = value_pat_from_name ~loc ptype_name.txt in
    let value_binding = Ast_builder.Default.value_binding ~loc ~pat ~expr in
    Ast_builder.Default.pstr_value ~loc Nonrecursive [value_binding]

  let from_type_decl ~loc ~path:_ (_rec_flag, tds) = List.map (from_td ~loc) tds
end

module Sig = struct
  let from_td ~loc td =
    let name = {txt = _name_from_type_name td.ptype_name.txt; loc} in
    let type_ = Util.core_type_from_type_decl ~loc td in
    let value_description = Ast_builder.Default.value_description ~loc ~name ~type_ ~prim:[] in
    Ast_builder.Default.psig_value ~loc value_description

  let from_type_decl ~loc ~path:_ (_rec_flag, tds) = List.map (from_td ~loc) tds
end

let from_str_type_decl = Deriving.Generator.make_noarg Str.from_type_decl

let from_sig_type_decl = Deriving.Generator.make_noarg Sig.from_type_decl
