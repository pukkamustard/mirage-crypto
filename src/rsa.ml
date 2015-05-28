open Sexplib.Conv
open Uncommon

exception Invalid_message

type pub  = { e : Z.t ; n : Z.t } with sexp

type priv = {
  e : Z.t ; d : Z.t ; n  : Z.t ;
  p : Z.t ; q : Z.t ; dp : Z.t ; dq : Z.t ; q' : Z.t
} with sexp

type mask = [ `No | `Yes | `Yes_with of Rng.g ]

let priv_of_primes ~e ~p ~q =
  let n  = Z.(p * q)
  and d  = Z.(invert e (pred p * pred q)) in
  let dp = Z.(d mod (pred p))
  and dq = Z.(d mod (pred q))
  and q' = Z.(invert q p) in
  { e; d; n; p; q; dp; dq; q' }

let pub_of_priv ({ e; n; _ } : priv) = { e ; n }

(* XXX handle this more gracefully... *)
let pub_bits  ({ n; _ } : pub)  = Numeric.Z.bits n
and priv_bits ({ n; _ } : priv) = Numeric.Z.bits n

let encrypt_unsafe ~key: ({ e; n } : pub) msg = Z.(powm msg e n)

let decrypt_unsafe ~key: ({ p; q; dp; dq; q'; _} : priv) c =
  let m1 = Z.(powm c dp p)
  and m2 = Z.(powm c dq q) in
  let h  = Z.(erem (q' * (m1 - m2)) p) in
  Z.(h * q + m2)

let decrypt_blinded_unsafe ?g ~key: ({ e; n; _} as key : priv) c =

  let rec nonce () =
    let x = Rng.Z.gen_r ?g Z.two n in
    if Z.(gcd x n = one) then x else nonce () in

  let r  = nonce () in
  let r' = Z.(invert r n) in
  let x  = decrypt_unsafe ~key Z.(powm r e n * c mod n) in
  Z.(r' * x mod n)


let (encrypt_z, decrypt_z) =
  let check_params n msg =
    if msg < Z.one || n <= msg then raise Invalid_message in
  (fun ~(key : pub) msg ->
    check_params key.n msg ;
    encrypt_unsafe ~key msg),
  (fun ?(mask = `Yes) ~(key : priv) msg ->
    check_params key.n msg ;
    match mask with
    | `No         -> decrypt_unsafe            ~key msg
    | `Yes        -> decrypt_blinded_unsafe    ~key msg
    | `Yes_with g -> decrypt_blinded_unsafe ~g ~key msg )

let reformat out f =
  Numeric.Z.(to_cstruct_be ~size:(cdiv out 8) &. f &. of_cstruct_be ?bits:None)

let encrypt ~key              = reformat (pub_bits key)  (encrypt_z ~key)
and decrypt ?(mask=`Yes) ~key = reformat (priv_bits key) (decrypt_z ~mask ~key)


let rec generate ?g ?(e = Z.(~$0x10001)) bits =
  if bits < 10 then
    invalid_arg "Rsa.generate: requested key size < 10 bits";
  if Numeric.(Z.bits e >= bits || not (pseudoprime e)) || e < Z.three then
    invalid_arg "Rsa.generate: e invalid or too small" ;

  let (pb, qb) = (bits / 2, bits - bits / 2) in
  let (p, q)   = Rng.(prime ?g ~msb:2 pb, prime ?g ~msb:2 qb) in
  let cond     = (p <> q) &&
                 Z.(gcd e (pred p) = one) &&
                 Z.(gcd e (pred q) = one) in
  if cond then
    priv_of_primes ~e ~p:(max p q) ~q:(min p q)
  else generate ?g ~e bits


module PKCS1 = struct

  let min_pad = 8 + 3

  open Cstruct

  let pad ~mark ~padding size msg =
    let n   = len msg in
    let pad = size - n
    and cs  = create size in
    BE.set_uint16 cs 0 mark ;
    padding (sub cs 2 (pad - 3)) ;
    set_uint8 cs (pad - 1) 0x00 ;
    blit msg 0 cs pad n ;
    cs

  let unpad ~mark ~is_pad cs =
    let n = len cs in
    let rec go ok i =
      if i = n then None else
        match (i, get_uint8 cs i) with
        | (0, b   ) -> go (b = 0x00 && ok) (succ i)
        | (1, b   ) -> go (b = mark && ok) (succ i)
        | (i, 0x00) when i >= min_pad && ok
                    -> ignore (go false (succ i)); Some (succ i)
        | (i, b   ) -> go (is_pad b && ok) (succ i) in
    go true 0 |> Option.map ~f:(fun off -> sub cs off (n - off))

  let pad_01 =
    pad ~mark:0x01 ~padding:(fun cs -> Cs.fill cs 0xff)

  let pad_02 ?g =
    pad ~mark:0x02 ~padding:(fun cs ->
      let n     = len cs in
      let block = Rng.(block_size * cdiv n block_size) in
      let rec go nonce i j =
        if i = n then () else
        if j = block then go Rng.(generate ?g block) i 0 else
          match get_uint8 nonce j with
          | 0x00 -> go nonce i (succ j)
          | x    -> set_uint8 cs i x ; go nonce (succ i) (succ j) in
      go Rng.(generate ?g block) 0 0
    )

  let unpad_01 = unpad ~mark:0x01 ~is_pad:(fun b -> b = 0xff)

  let unpad_02 = unpad ~mark:0x02 ~is_pad:(fun b -> b <> 0x00)

  let padded pad transform keybits msg =
    let size = cdiv keybits 8 in
    if size - len msg < min_pad then raise Invalid_message ;
    transform (pad size msg)

  let unpadded unpad transform keybits msg =
    if len msg = cdiv keybits 8 then
      try unpad (transform msg) with Invalid_message -> None
    else None

  let sign ?mask ~key msg =
    padded pad_01 (decrypt ?mask ~key) (priv_bits key) msg

  let verify ~key msg =
    unpadded unpad_01 (encrypt ~key) (pub_bits key) msg

  let encrypt ?g ~key msg =
    padded (pad_02 ?g) (encrypt ~key) (pub_bits key) msg

  let decrypt ?mask ~key msg =
    unpadded unpad_02 (decrypt ?mask ~key) (priv_bits key) msg

end

let (bx00, bx01, bxbc) =
  let f b = Cs.of_bytes [b] in
  (f 0x00, f 0x01, f 0xbc)

module MGF1 (H : Hash.T) = struct

  open Cstruct
  open Numeric

  let repr = Numeric.Int32.to_cstruct_be ~size:4

  (* Assumes len < 2^32 * H.digest_size. *)
  let mgf ~seed ~len =
    Range.of_int32 0l (Int32.of_int @@ cdiv len H.digest_size - 1)
    |> List.map (fun c -> H.digestv [seed; repr c])
    |> Cs.concat
    |> fun cs -> sub cs 0 len

  let mask ~seed cs = Cs.xor (mgf ~seed ~len:(len cs)) cs

end

let mask = true

module OAEP (H : Hash.T) = struct

  open Cstruct

  module MGF = MGF1(H)

  let hlen = H.digest_size

  let msg_limit ~key = cdiv (pub_bits key) 8 - 2 * hlen - 2

  let eme_oaep_encode ?g ?(label = Cs.empty) ~key msg =
    let seed  = Rng.generate ?g hlen
    and pad   = Cs.zeros (msg_limit ~key - len msg) in
    let db    = Cs.concat [ H.digest label ; pad ; bx01 ; msg ] in
    let mdb   = MGF.mask ~seed db in
    let mseed = MGF.mask ~seed:mdb seed in
    Cs.concat [ bx00 ; mseed ; mdb ]

  let eme_oaep_decode ?(label = Cs.empty) msg =
    let (b0, ms, mdb) = Cs.split3 msg 1 hlen in
    let db = MGF.mask ~seed:(MGF.mask ~seed:mdb ms) mdb in
    let i  = Cs.find_uint8 ~mask ~off:hlen ~f:((<>) 0x00) db
             |> Option.value ~def:0
    in
    let c1 = Cs.equal ~mask (sub db 0 hlen) H.(digest label)
    and c2 = get_uint8 b0 0 = 0x00
    and c3 = get_uint8 db i = 0x01 in
    if c1 && c2 && c3 then Some (shift db (i + 1)) else None

  let encrypt ?g ?label ~key msg =
    if len msg > msg_limit ~key then
      raise Invalid_message
    else encrypt ~key @@ eme_oaep_encode ?g ?label ~key msg

  let decrypt ?mask ?label ~key msg =
    let k = cdiv (priv_bits key) 8 in
    if len msg <> k || k < 2 * hlen + 2 then
      None
    else try
      eme_oaep_decode ?label @@ decrypt ?mask ~key msg
    with Invalid_message -> None

  (* XXX Review rfc3447 7.1.2 and
   * http://archiv.infsec.ethz.ch/education/fs08/secsem/Manger01.pdf
   * again for timing properties. *)

  (* XXX expose seed for deterministic testing? *)

end

module PSS (H: Hash.T) = struct

  open Cstruct

  module MGF = MGF1(H)

  let hlen  = H.digest_size

  let b0mask embits = 0xff lsr ((8 - embits mod 8) mod 8)

  let emsa_pss_encode ?g slen bits msg =
    (* If emLen < hLen + sLen + 2, output "encoding error" and stop. *)
    let n    = cdiv bits 8
    and salt = Rng.generate ?g slen in
    let h    = H.digestv [ Cs.zeros 8 ; H.digest msg ; salt ] in
    let db   = Cs.concat [ Cs.zeros (n - slen - hlen - 2) ; bx01 ; salt ] in
    let mdb  = MGF.mask ~seed:h db in
    set_uint8 mdb 0 @@ get_uint8 mdb 0 land b0mask bits ;
    Cs.concat [ mdb ; h ; bxbc ]

  let emsa_pss_verify slen bits em msg =
    let (mdb, h, bxx) = Cs.split3 em (em.len - hlen - 1) hlen in
    let db   = MGF.mask ~seed:h mdb in
    set_uint8 db 0 (get_uint8 db 0 land b0mask bits) ;
    let salt = shift db (len db - slen) in
    let h'   = H.digestv [ Cs.zeros 8 ; H.digest msg ; salt ]
    and i    = Cs.find_uint8 ~mask ~f:((<>) 0) db |> Option.value ~def:0
    in
    let c1 = lnot (b0mask bits) land get_uint8 mdb 0 = 0x00
    and c2 = i = em.len - hlen - slen - 2
    and c3 = get_uint8 db  i = 0x01
    and c4 = get_uint8 bxx 0 = 0xbc
    and c5 = Cs.equal ~mask h h' in
    c1 && c2 && c3 && c4 && c5

  let sign ?g ?(seedlen = hlen) ~key msg =
    let em = emsa_pss_encode ?g seedlen (priv_bits key - 1) msg in
    decrypt ~mask:`No ~key em

  let verify ?(seedlen = hlen) ~key ~signature msg =
    let bits = pub_bits key - 1 in
    let k    = bytes bits
    and em   = encrypt ~key signature in
    emsa_pss_verify seedlen bits (sub em (len em - k) k) msg

end
