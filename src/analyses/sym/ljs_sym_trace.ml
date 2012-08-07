open Prelude
open Lexing
open Ljs_sym_values
open FormatExt

(*type trace_pt = Pos.t * label*) (* from ljs_sym_values *)
type path = trace_pt list
type vid = string (* uniq vertex id *)
type trace =
  | TEmpty of vid
  | TResult of vid * value result list
  | TBranch of vid * Pos.t * (label * trace) list

(* Helpers to get the corresponding LJS code for a pos. *)
let read_len inch len =
  try begin
    let result = String.create len in
    really_input inch result 0 len;
    result
  end with Invalid_argument _ -> sprintf "invalid pos %d" len

let read_pos (start, endd, _) =
  let inch = open_in start.pos_fname in
  let len = endd.pos_cnum - start.pos_cnum in
  seek_in inch start.pos_cnum;
  let result = read_len inch len in
  close_in inch;
  if result = "" then "???" else
  if start.pos_lnum = endd.pos_lnum then result
  else (String.sub result 0 (String.index result '\n')) ^ "..."

let string_of_pos p =
  read_pos p ^ " (" ^ Pos.string_of_pos p ^ ")"

(* Printing traces as tree-like strings *)
let rec trace_print t = match t with
  | TEmpty _ -> text "<empty>"
  | TResult (_, results) -> begin
    horz (intersperse (text "|") (map
      (fun result ->
        match result with
        | Value (v, pc) -> text (Ljs_sym_pretty.val_to_string v)
        | Exn (ev, pc) -> begin
          match ev with
          | Throw v -> text (Ljs_sym_pretty.val_to_string v)
          | _ -> text "Exn"
        end
        | Unsat pc -> text "<unsat>")
      results))
  end
  | TBranch (_, pos, branches) ->
    vert (text (string_of_pos pos)
      :: (map (fun (label, t) ->
                horz [text label; text ":"; trace_print t])
            branches))

let string_of_trace = to_string trace_print

(* Printing traces in graphviz Dot format.
 * To convert the dot output to an image,
 * install graphviz and run something like:
 * dot -Tpng trace.dot -o trace.png
 * or replace png with the format of your choice. *)

let str_contains str substr =
  Str.string_match (Str.regexp_string substr) str 0

let dot_of_trace trace =
  let dot_of_vertex vid label attrs =
    sprintf "%s [label=\"%s\"%s];\n" vid (String.escaped label) attrs
  in
  let rec vertices_helper trace = match trace with
    | TEmpty vid -> dot_of_vertex vid (string_of_trace trace) ""
    | TResult (vid, results) ->
        let label = string_of_trace trace in
        let color =
          if label = "<unsat>" then ",fontcolor=red" else
          if str_contains label "Exn:" then ",fontcolor=darkgreen"
          else ",fontcolor=blue"
        in dot_of_vertex vid label color
    | TBranch (vid, pos, branches) ->
        String.concat ""
          (dot_of_vertex vid (string_of_pos pos) ",fontname=Courier"
          :: map vertices_helper (map snd branches))
  in
  let dot_of_edge vid1 vid2 label =
    sprintf "%s -> %s [label=\"%s\"];\n" vid1 vid2 (String.escaped label)
  in
  let rec edges_helper trace = match trace with
    | TEmpty _ | TResult _ -> ""
    | TBranch (vid, pos, branches) ->
        String.concat ""
          ((map (fun (edge_label, subtrace) ->
                   match subtrace with
                   | TEmpty subvid | TResult (subvid, _) 
                   | TBranch (subvid, _, _) ->
                   dot_of_edge vid subvid edge_label)
            branches)
          @ map edges_helper (map snd branches))
  in
  "digraph {\n"
  ^ "node [shape=plaintext];\n"
  ^ vertices_helper trace
  ^ edges_helper trace
  ^ "}"

(* Returns the list where the oldval associated with the first occurrence
 * of key is replaced with (replace oldval). If key not in the list, appends the pair *)
let rec replace_assoc (key : 'a) (replace : ('b option -> 'b)) (assoc : ('a * 'b) list)
      : ('a * 'b) list =
  match assoc with
  | [] -> [(key, replace None)]
  | (k, v)::assoc ->
    if k = key
    then (key, (replace (Some v)))::assoc
    else (k, v)::(replace_assoc key replace assoc)

let next_vid =
  let count = ref 0 in
  (fun () -> incr count; "v" ^ string_of_int !count)

let rec trace_of_path (res, path) =
  match path with
  | [] -> TResult (next_vid(), [res])
  | (pos, label)::path ->
    TBranch (next_vid(), pos, [(label, trace_of_path (res, path))])

let next_exn_hack_id =
  let count = ref 0 in
  (fun () -> incr count; "exnhack" ^ string_of_int !count)

(* Optimized for when trace2 is linear. *)
let rec merge_traces trace1 trace2 = match trace1, trace2 with
  | TEmpty _, t
  | t, TEmpty _ -> t
  | TResult (vid, rs1), TResult (_, rs2) -> TResult (vid, rs2 @ rs1)
  | TBranch (vid, pos1, branches1), TBranch (_, pos2, branches2) ->
    if pos1 <> pos2 then failwith "Pos mismatch" else
    let new_branches =
      fold_left
        (fun branches1 (label2, subt2) ->
           replace_assoc label2
             (fun subt1 -> match subt1 with
              | Some subt1 -> merge_traces subt1 subt2
              | None -> subt2)
             branches1)
        branches1 branches2 in
    TBranch (vid, pos1, new_branches)
  (* Hack for when exceptions pop up without first performing
   * a proper branching. We shove them into whatever sibling branching
   * we come across. The pos in that branch won't necessarily represent
   * the pos where the exception was thrown, but it might be close. *)
  | TBranch (vid1, pos, branches), TResult (vid2, r)
  | TResult (vid2, r), TBranch (vid1, pos, branches) ->
      TBranch (vid1, pos, (next_exn_hack_id(), TResult (vid2, r))::branches) 

let trace_of_results results =
  let results = map (fun (res, path) -> (res, List.rev path)) results in
  let traces = map trace_of_path results in
  fold_left merge_traces (TEmpty (next_vid())) traces
