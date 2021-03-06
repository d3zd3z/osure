(* Scanning *)

open Core

module Internal : sig

  (** Augment the node coming from a sure tree to track the full path. *)
  val track_path : string -> Node.t Sequence.t -> (Node.t * string) Sequence.t

  (** Determine if the given node should have a hash, but is missing
   * one.  The node must be a "file" not, with a kind of "file", and not
   * already have a sha1 attribute. *)
  val needs_hash : Node.t -> bool

end = struct

  (** Reverse and combine the components into a path. *)
  let revcombine = function
    | [] -> "."
    | elts -> List.reduce_exn (List.rev elts) ~f:(^/)

  let track_path root seq =
    Sequence.folding_map seq ~init:([root], root) ~f:(fun (elts, path) node ->
      match node with
        | Node.Enter ("__root__", _) when List.length elts = 1 ->
            (* The root directory is a special case, we use the passed
             * in name instead of the "__root__" that will be in the
             * node.  There isn't anything preventing the name
             * "__root__" from occurring elsewhere, but it saves us from
             * having to compute the element list length every time. *)
            ((elts, path), (node, path))
        | Node.Enter (name, _) ->
            let elts = name :: elts in
            let path = revcombine elts in
            ((elts, path), (node, path))
        | Leave ->
            let elts = match elts with
              | [] -> failwith "Too many Leave nodes"
              | (_::elts) -> elts in
            let path = revcombine elts in
            ((elts, path), (node, path))
        | Sep ->
            ((elts, path), (node, path))
        | File (name, _) ->
            ((elts, path), (node, path ^/ name)))

  let needs_hash = function
    | Node.Enter _ | Leave | Sep -> false
    | File (_, atts) ->
        begin match Map.find atts "kind" with
          | Some "file" -> not (Map.mem atts "sha1")
          | _ -> false
        end
end

open Internal

let to_seq f =
  Sequence.unfold ~init:f ~f:(fun f ->
    Option.map (f ()) ~f:(fun node -> (node, f)))
  |> Sequence.memoize

module HashState = struct
  type t = {
    mutable files : int64;
    mutable tfiles : int64;
    mutable octets : int64;
    mutable toctets : int64;
    meter : Progress.t;
  }
  let show t = sprintf "%Ld files, %Ld bytes" t.tfiles t.toctets
end

let node_size = function
  | Node.File (_, atts) ->
      begin match Map.find atts "size" with
        | None -> 0L
        | Some text -> Int64.of_string text
      end
  | _ -> 0L

let hash_count ~meter prior =
  let state = { HashState.files = 0L; tfiles = 0L;
    octets = 0L; toctets = 0L; meter } in
  Sequence.iter (to_seq prior) ~f:(fun node ->
    if needs_hash node then begin
      state.tfiles <- Int64.succ state.tfiles;
      state.toctets <- Int64.(+) state.toctets (node_size node)
    end);
  state

let update_meter (hstate : HashState.t) node =
  hstate.files <- Int64.succ hstate.files;
  hstate.octets <- Int64.(+) hstate.octets (node_size node);
  Progress.update hstate.meter ~f:(fun () ->
    sprintf "  %6Ld/%6Ld (%5.1f%%) files, %s/%s (%5.1f%%) bytes"
      hstate.files hstate.tfiles
      Float.(Int64.to_float hstate.files * 100.0 / Int64.to_float hstate.tfiles)
      (Progress.humanize_size hstate.octets)
      (Progress.humanize_size hstate.toctets)
      Float.(Int64.to_float hstate.octets * 100.0 / Int64.to_float hstate.toctets))

(** A Hashing module performs updates of the hash database. *)
module type Hasher = sig
  type t
  val make : hstate:HashState.t -> Sqlite3.db -> t
  val hash_file : t -> int -> Node.t -> string -> unit
  val finalize : t -> unit
end

(** Hashing module that computes hashes and adds them to the database,
 * all within a single thread. *)
module Direct_hash : Hasher = struct
  type t = {
    hstate : HashState.t;
    db : Sqlite3.db;
    stmt : Sqlite3.stmt;
  }

  let make ~hstate db =
    let stmt = Sqlite3.prepare db "INSERT INTO hashes VALUES (?, ?)" in
    { hstate; db; stmt }

  let hash_file t index node path =
    let hash = try Some (Sha1.hash_file path) with
    | _ex ->
        eprintf "Warning: error hashing %S\n" path;
        None
    in
    update_meter t.hstate node;

    Option.iter hash ~f:(fun hash ->
      Sqlite3.bind_int t.stmt 1 index |> Sqlite3.Rc.check;
      Sqlite3.bind_blob t.stmt 2 hash |> Sqlite3.Rc.check;
      begin match Sqlite3.step t.stmt with
      | DONE -> ()
      | err -> failwith (Sqlite3.Rc.to_string err)
      end;
      Sqlite3.reset t.stmt |> Sqlite3.Rc.check
    )

  let finalize t =
    Sqlite3.finalize t.stmt |> Sqlite3.Rc.check
end

module Threaded_hash : Hasher = struct

  (* Number of cpus.  This should actually get from the system. *)
  let ncpu = 4

  let nworkers = ncpu

  (* We create n+1 threads, where the n threads run hash_worker, and
   * the remaining thread runs hash_collector. *)

  type t = {
    (* The work queue.  The main thread will write to this, and the
     * workers will pull from it.  When the main thread is done, it
     * will push a None for each worker to indicate they should
     * finish. *)
    work : (int * Node.t * string) option Channel.t;

    (* The workers push their state to the finish queue as they hash.
     * Each worker will also push a None to indicate they are finished
     * with all of their work. *)
    finish : (int * Node.t * string) option Channel.t;

    (* The threads. *)
    collector : Thread.t;
  }

  let hash_collector finish ~hstate db =
    let stmt = Sqlite3.prepare db "INSERT INTO hashes VALUES (?, ?)" in
    let rec loop workers =
      if workers = 0 then ()
      else match Channel.pop finish with
        | None -> loop (workers-1)
        | Some (index, node, hash) ->
            update_meter hstate node;
            Sqlite3.bind_int stmt 1 index |> Sqlite3.Rc.check;
            Sqlite3.bind_blob stmt 2 hash |> Sqlite3.Rc.check;
            begin match Sqlite3.step stmt with
              | DONE -> ()
              | err -> failwith (Sqlite3.Rc.to_string err)
            end;
            Sqlite3.reset stmt |> Sqlite3.Rc.check;
            loop workers
    in loop nworkers;
    Sqlite3.finalize stmt |> Sqlite3.Rc.check

  let rec hash_worker t =
    match Channel.pop t.work with
      | None ->
          Channel.push t.finish None
      | Some (index, node, path) ->
          let hash = try Some (Sha1.hash_file path) with
            | _ex ->
                eprintf "Warning: error hashing %S\n%!" path;
                None
          in
          Option.iter hash ~f:(fun hash ->
            Channel.push t.finish (Some (index, node, hash)));
          hash_worker t

  let make ~hstate db =
    let finish = Channel.create ~bound:(2 * ncpu) in
    let collector = Thread.create (hash_collector finish ~hstate) db
      ~on_uncaught_exn:`Kill_whole_process
    in
    let t = {
      work = Channel.create ~bound:(2 * ncpu);
      finish;
      collector } in
    for _ = 1 to nworkers do
      let _ = Thread.create hash_worker t ~on_uncaught_exn:`Kill_whole_process in
      ()
    done;
    t

  let hash_file t index node path =
    Channel.push t.work (Some (index, node, path))

  let finalize t =
    (* Tell all of the workers we are done. *)
    for _ = 1 to nworkers do
      Channel.push t.work None
    done;

    (* Wait for the collector to finish. *)
    Thread.join t.collector
end

module Hash_update (H : Hasher) = struct
  let hash_update ~hstate path db prior =
    printf "hash update\n";
    let nodes = to_seq prior in
    let nodes = track_path path nodes in
    Db.with_xact db ~f:(fun db ->
      let hasher = H.make ~hstate db in
      Sequence.iteri nodes ~f:(fun index (node, path) ->
        if needs_hash node then begin
          (*printf "Node: %s\n" (Node.show node);*)
          (*printf "  %S\n" path;*)
          H.hash_file hasher index node path
        end);
      H.finalize hasher)
end

(* include Hash_update (Direct_hash) *)
include (Hash_update (Threaded_hash))

(** Update the hash within a node. *)
let node_newhash node newhash =
  let newhash = Sha1.hexlify newhash in
  match node with
    | Node.File (name, atts) ->
        Node.File (name, Map.set atts ~key:"sha1" ~data:newhash)
    | _ -> failwith "Node sequence error"

let merge_hashes elts rnode wnode =
  let input = to_seq rnode in
  let input = Sequence.mapi input ~f:(fun index node -> (index, node)) in
  let rec loop = function
    | (None, None) -> ()
    | (Some (_, anext), None) -> loop (Sequence.next anext, None)
    | (None, Some ((_, bnode), bnext)) ->
        wnode bnode;
        loop (None, Sequence.next bnext)
    | (Some ((aindex, aelt), anext) as aa, (Some ((bindex, belt), bnext) as bb)) ->
        if aindex < bindex then
          loop (Sequence.next anext, bb)
        else if aindex > bindex then begin
          wnode belt;
          loop (aa, Sequence.next bnext)
        end else begin
          (* Update *)
          let belt = node_newhash belt aelt in
          wnode belt;
          loop (Sequence.next anext, Sequence.next bnext)
        end
  in
  loop (Sequence.next elts, Sequence.next input)

let must_dir = function
  | Node.Enter (name, _) -> name
  | _ -> failwith "Unexpected node type"

let is_file atts = match Map.find atts "kind" with
  | Some "file" -> true
  | _ -> false

(** Determine if these sets of attributes are similar enough to copy
 * the 'sha1' from the older set to the newer. *)
let migrate_hash older newer =
  (* printf "older: %s\n" (Node.show (Node.File ("fake", older))); *)
  (* printf "newer: %s\n" (Node.show (Node.File ("fake", newer))); *)
  (* Don't do anything if a hash exists already *)
  if Map.mem newer "sha1" then newer
  (* Don't copy unless both are files. *)
  else if not (is_file older && is_file newer) then newer
  else begin
    let attsame key =
      match (Map.find older key, Map.find newer key) with
        | (Some v1, Some v2) when String.(v1 = v2) -> true
        | _ -> false
    in
    match Map.find older "sha1" with
      | None -> newer
      | Some sha1 ->
          if attsame "ino" && attsame "ctime" then
            Map.set newer ~key:"sha1" ~data:sha1
          else
            newer
  end

let cp_hashes ~older ~latest out =
  let next gen = match gen () with
    | Some node -> node
    | None -> failwith "Unexpected end of tree" in

  let rec children anode bnode = match (anode, bnode) with
    | (Node.Sep, Node.Sep) ->
        out Node.Sep;
        files (next older) (next latest)
    | (Enter _, Sep) ->
        aconsume ();
        children (next older) bnode
    | (Sep, Enter _) ->
        out bnode;
        bconsume ();
        children anode (next latest)
    | (Enter (aname, _), Enter (bname, _)) when String.(aname < bname) ->
        aconsume ();
        children (next older) bnode
    | (Enter (aname, _), Enter (bname, _)) when String.(aname > bname) ->
        out bnode;
        bconsume ();
        children anode (next latest)
    | (Enter _, Enter _) ->
        out bnode;
        children (next older) (next latest);
        children (next older) (next latest);
    | _ -> failwith "Invalid node in tree"
  and files anode bnode = match (anode, bnode) with
    | (Node.Leave, Node.Leave) -> out bnode
    | (File _, Leave) ->
        files (next older) bnode
    | (Leave, File _) ->
        out bnode;
        files anode (next latest)
    | (File (aname, _), File (bname, _)) when String.(aname < bname) ->
        files (next older) bnode
    | (File (aname, _), File (bname, _)) when String.(aname > bname) ->
        out bnode;
        files anode (next latest)
    | (File (_, aatts), File (bname, batts)) ->
        let batts = migrate_hash aatts batts in
        out (File (bname, batts));
        files (next older) (next latest)
    | _ -> failwith "Invalid node in file part of tree"
  and aconsume () =
    let node = next older in
    match node with
      | Node.Leave -> ()
      | Sep | File _ -> aconsume ()
      | Enter _ -> aconsume (); aconsume ()
  and bconsume () =
    let node = next latest in
    out node;
    match node with
      | Node.Leave -> ()
      | Sep | File _ -> bconsume ()
      | Enter _ -> bconsume (); bconsume ()
  in

  let a = next older in
  let b = next latest in

  out b;

  let aname = must_dir a in
  let bname = must_dir b in

  if String.(aname <> bname) then failwith "Root directories have differing names";
  children (next older) (next latest)
