(** IPC wiring for market data and order intake.
    
    Currently uses Unix domain sockets for prototyping.
    Can be replaced with Aeron IPC when aeroon bindings are stable.
*)

type t

val create : unit -> t

val poll_once : t -> Market_state.t -> unit
