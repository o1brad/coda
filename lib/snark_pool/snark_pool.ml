open Protocols
open Core_kernel
open Async_kernel
open Coda_pow

module Priced_proof = struct
  type ('proof, 'fee) t = {proof: 'proof; fee: 'fee}
  [@@deriving bin_io, fields]
end

module type S = sig
  type work

  type proof

  type fee

  type priced_proof

  type t

  val create_pool : unit -> t

  val add_snark : t -> work:work -> proof:proof -> fee:fee -> unit

  val request_proof : t -> work -> priced_proof option

  val add_unsolved_work : t -> work -> unit

  (* TODO: Include my_fee as a paramter for request work and 
          return work that has a fee less than my_fee if the 
          returned work does not have any unsolved work *)

  val request_work : t -> work option

  val gen :
       proof Quickcheck.Generator.t
    -> fee Quickcheck.Generator.t
    -> work Quickcheck.Generator.t
    -> t Quickcheck.Generator.t
end

module Make (Proof : sig
  type t [@@deriving bin_io]

  include Proof_intf with type t := t
end) (Fee : sig
  type t [@@deriving bin_io]

  include Comparable.S with type t := t
end) (Work : sig
  type t [@@deriving bin_io]

  include Hashable.S_binable with type t := t
end) :
  sig
    include S

    val unsolved_work_count : t -> int

    val remove_solved_work : t -> work -> unit

    val to_record : priced_proof -> (proof, fee) Priced_proof.t

    val solved_work : t -> work list

    val unsolved_work : t -> work list
  end
  with type work := Work.t
   and type proof := Proof.t
   and type fee := Fee.t =
struct
  module Work_random_set = Random_set.Make (Work)

  module Priced_proof = struct
    type t = (Proof.t, Fee.t) Priced_proof.t [@@deriving bin_io]

    let create proof fee : (Proof.t, Fee.t) Priced_proof.t = {proof; fee}

    let proof (t: t) = t.proof

    let fee (t: t) = t.fee
  end

  let to_record priced_proof =
    Priced_proof.create
      (Priced_proof.proof priced_proof)
      (Priced_proof.fee priced_proof)

  type priced_proof = Priced_proof.t

  type t =
    { proofs: Priced_proof.t Work.Table.t
    ; solved_work: Work_random_set.t
    ; unsolved_work: Work_random_set.t }
  [@@deriving bin_io]

  let solved_work t = Work_random_set.to_list t.solved_work

  let unsolved_work t = Work_random_set.to_list t.unsolved_work

  let create_pool () =
    { proofs= Work.Table.create ()
    ; solved_work= Work_random_set.create ()
    ; unsolved_work= Work_random_set.create () }

  let add_snark t ~work ~proof ~fee =
    let open Option in
    let smallest_priced_proof =
      Work.Table.find t.proofs work
      >>| (fun {proof= existing_proof; fee= existing_fee} ->
            if existing_fee <= fee then
              Priced_proof.create existing_proof existing_fee
            else {proof; fee} )
      |> Option.value ~default:(Priced_proof.create proof fee)
    in
    Work.Table.set t.proofs work smallest_priced_proof ;
    Work_random_set.add t.solved_work work

  let request_proof t = Work.Table.find t.proofs

  let add_unsolved_work t = Work_random_set.add t.unsolved_work

  let remove_solved_work t work =
    Work_random_set.remove t.solved_work work ;
    Work.Table.remove t.proofs work

  (* TODO: We request a random piece of work if there is unsolved work. 
           If there is no unsolved work, then we choose a uniformly random 
           piece of work from the solved work pool. We need to use different
           heuristics since there will be high contention when the work pool is small.
           See issue #276 *)
  let request_work t =
    let ( |? ) maybe default =
      match maybe with Some v -> Some v | None -> Lazy.force default
    in
    let open Option.Let_syntax in
    (let%map work = Work_random_set.get_random t.unsolved_work in
     Work_random_set.remove t.unsolved_work work ;
     work)
    |? lazy
         (let%map work = Work_random_set.get_random t.solved_work in
          remove_solved_work t work ; work)

  let unsolved_work_count t = Work_random_set.length t.unsolved_work

  let gen proof_gen fee_gen work_gen =
    let open Quickcheck in
    let open Quickcheck.Generator.Let_syntax in
    let gen_entry () =
      Quickcheck.Generator.tuple3 proof_gen fee_gen work_gen
    in
    let%map sample_solved_work = Quickcheck.Generator.list (gen_entry ())
    and sample_unsolved_solved_work = Quickcheck.Generator.list work_gen in
    let pool = create_pool () in
    List.iter sample_solved_work ~f:(fun (proof, fee, work) ->
        add_snark pool work proof fee ) ;
    List.iter sample_unsolved_solved_work ~f:(fun work ->
        add_unsolved_work pool work ) ;
    pool
end

let%test_module "snark pool test" =
  ( module struct
    module Mock_proof = struct
      type input = Int.t

      type t = Int.t [@@deriving sexp, bin_io]

      let verify _ _ = return true

      let gen = Int.gen
    end

    module Mock_work = Int
    module Mock_fee = Int

    module Mock_Priced_proof = struct
      type proof = Mock_proof.t [@@deriving sexp, bin_io]

      type fee = Mock_fee.t [@@deriving sexp, bin_io]

      type t = {proof: proof; fee: fee} [@@deriving sexp, bin_io]

      let proof t = t.proof
    end

    module Mock_snark_pool = struct
      include Make (Mock_proof) (Mock_fee) (Mock_work)

      type t' = {solved_work: Mock_work.t list; unsolved_work: Mock_work.t list}
      [@@deriving sexp]

      let sexp_of_t t =
        [%sexp_of : t']
          {solved_work= solved_work t; unsolved_work= unsolved_work t}
    end

    type t = {solved_work: Mock_work.t list; unsolved_work: Mock_work.t list}

    let gen = Mock_snark_pool.gen Mock_proof.gen Mock_fee.gen Mock_work.gen

    let%test_unit "When two priced proofs of the same work are inserted into \
                   the snark pool, the fee of the work is at most the minimum \
                   of those fees" =
      let gen_entry () =
        Quickcheck.Generator.tuple2 Mock_proof.gen Mock_fee.gen
      in
      Quickcheck.test
        ~sexp_of:
          [%sexp_of
            : Mock_snark_pool.t
              * Mock_work.t
              * (Mock_proof.t * Mock_fee.t)
              * (Mock_proof.t * Mock_fee.t)]
        (Quickcheck.Generator.tuple4 gen Mock_work.gen (gen_entry ())
           (gen_entry ()))
        ~f:(fun (t, work, (proof_1, fee_1), (proof_2, fee_2)) ->
          Mock_snark_pool.add_snark t work proof_1 fee_1 ;
          Mock_snark_pool.add_snark t work proof_2 fee_2 ;
          let fee_upper_bound = Mock_fee.min fee_1 fee_2 in
          let {Priced_proof.fee; _} =
            Mock_snark_pool.to_record
            @@ Option.value_exn (Mock_snark_pool.request_proof t work)
          in
          assert (fee <= fee_upper_bound) )

    let%test_unit "A priced proof of a work will replace an existing priced \
                   proof of the same work only if it's fee is smaller than \
                   the existing priced proof" =
      Quickcheck.test
        ~sexp_of:
          [%sexp_of
            : Mock_snark_pool.t
              * Mock_work.t
              * Mock_fee.t
              * Mock_fee.t
              * Mock_proof.t
              * Mock_proof.t]
        (Quickcheck.Generator.tuple6 gen Mock_work.gen Mock_fee.gen
           Mock_fee.gen Mock_proof.gen Mock_proof.gen) ~f:
        (fun (t, work, fee_1, fee_2, cheap_proof, expensive_proof) ->
          Mock_snark_pool.remove_solved_work t work ;
          let expensive_fee = max fee_1 fee_2
          and cheap_fee = min fee_1 fee_2 in
          Mock_snark_pool.add_snark t work cheap_proof cheap_fee ;
          Mock_snark_pool.add_snark t work expensive_proof expensive_fee ;
          assert (
            {Priced_proof.fee= cheap_fee; proof= cheap_proof}
            = Mock_snark_pool.to_record
              @@ Option.value_exn (Mock_snark_pool.request_proof t work) ) )

    let%test_unit "Remove unsolved work if unsolved work pool is not empty" =
      Quickcheck.test ~sexp_of:[%sexp_of : Mock_snark_pool.t * Mock_work.t]
        (Quickcheck.Generator.tuple2 gen Mock_work.gen) ~f:(fun (t, work) ->
          let open Quickcheck.Generator.Let_syntax in
          Mock_snark_pool.add_unsolved_work t work ;
          let size = Mock_snark_pool.unsolved_work_count t in
          ignore @@ Mock_snark_pool.request_work t ;
          assert (size - 1 = Mock_snark_pool.unsolved_work_count t) )
  end )