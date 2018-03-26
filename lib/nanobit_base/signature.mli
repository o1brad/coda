open Core

type t = Bignum.Bigint.t * Bignum.Bigint.t
[@@deriving compare]

module Stable : sig
  module V1 : sig
    type t = Bignum.Bigint.Stable.V1.t * Bignum.Bigint.Stable.V1.t
    [@@deriving sexp, bin_io, compare]
  end
end

open Snark_params.Tick

type var = Boolean.var list * Boolean.var list
val typ : (var, t) Typ.t
