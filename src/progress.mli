(** A generalized progress meter. *)

open Core

(** The type of a progress meter. *)
type t

(** Perform some operation with a progress meter present. *)
val with_meter : f:(t -> 'a) -> 'a

(** Insert a meter to show 'scan' progress. *)
val scan_meter : t -> Node.t Sequence.t -> Node.t Sequence.t

(** Update what would be shown on the meter. *)
val update : t -> f:(unit -> string) -> unit

(** Convert a file size to a readable summary form. *)
val humanize_size : int64 -> string
