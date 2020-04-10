open Types
open Rresult

(* RFC 4880: 5.5.2 Public-Key Packet Formats *)

type parse_error = [ `Incomplete_packet | `Msg of string]

type public_key_asf =
  | DSA_pubkey_asf of Mirage_crypto_pk.Dsa.pub
  | Elgamal_pubkey_asf of { p: mpi ; g: mpi ; y: mpi }
  | RSA_pubkey_sign_asf of Mirage_crypto_pk.Rsa.pub
  | RSA_pubkey_encrypt_asf of Mirage_crypto_pk.Rsa.pub
  | RSA_pubkey_encrypt_or_sign_asf of Mirage_crypto_pk.Rsa.pub

let pp_pk_asf ppf asf=
  let pp_rsa ppf (pk:Mirage_crypto_pk.Rsa.pub) =
    Fmt.pf ppf "%d-bit (e: %a) RSA"
      (Z.numbits pk.n) Z.pp_print pk.e
  in
  match asf with
  | DSA_pubkey_asf pk -> Fmt.pf ppf "%d-bit DSA key" (Z.numbits pk.p)
  | Elgamal_pubkey_asf _ -> Fmt.string ppf "El-Gamal key TODO unimplemented"
  | RSA_pubkey_sign_asf pk -> Fmt.pf ppf "%a signing key" pp_rsa pk
  | RSA_pubkey_encrypt_asf pk -> Fmt.pf ppf "%a encryptionsigning key" pp_rsa pk
  | RSA_pubkey_encrypt_or_sign_asf pk -> Fmt.pf ppf "%a encryption & signing key" pp_rsa pk

let public_key_algorithm_of_asf = function
  | DSA_pubkey_asf _ -> DSA
  | RSA_pubkey_sign_asf _ -> RSA_sign_only
  | RSA_pubkey_encrypt_asf _ -> RSA_encrypt_only
  | RSA_pubkey_encrypt_or_sign_asf _ -> RSA_encrypt_or_sign
  | Elgamal_pubkey_asf _ -> Elgamal_encrypt_only

type private_key_asf =
  | DSA_privkey_asf of Mirage_crypto_pk.Dsa.priv
  | RSA_privkey_asf of Mirage_crypto_pk.Rsa.priv
  | Elgamal_privkey_asf of { x : mpi}

type t =
  { timestamp: Ptime.t
  ; algorithm_specific_data : public_key_asf
  ; v4_fingerprint : Cs.t
  }

type private_key =
  { public : t
  ; priv_asf : private_key_asf
  }

let pp ppf t =
  (* TODO vbox / hbox *)
  Fmt.pf ppf "[ Created: %a@,; %a@,; SHA1 fingerprint: %s ]"
    Ptime.pp t.timestamp
    pp_pk_asf t.algorithm_specific_data
    (Cs.to_hex t.v4_fingerprint)

let pp_secret ppf t = pp ppf t.public (* TODO *)

let cs_of_public_key_asf asf =
  Logs.debug (fun m -> m "cs_of_public_key_asf called");
  begin match asf with
  | DSA_pubkey_asf {Mirage_crypto_pk.Dsa.p;q;gg;y} -> [p;q;gg;y]
  | Elgamal_pubkey_asf { p ; g ; y } -> [ p; g; y ]
  | RSA_pubkey_sign_asf p
  | RSA_pubkey_encrypt_or_sign_asf p
  | RSA_pubkey_encrypt_asf p -> [ p.n ; p.e ]
  end
  |> cs_of_mpi_list

let rsa_q_prime ~p ~q =
  (* here because nocrypto's sk.q' is some other number?? *)
  Logs.warn (fun m -> m "TODO should this RSA ((p**-1) %% q) be blinded??") ;
  Z.invert p q

let rsa_d_secret_exponent ~e ~p ~q =
  (* here because nocrypto's sk.d seems to be some other number?? *)
  Logs.warn (fun m -> m "TODO should this RSA d computation be blinded?");
  Z.invert e @@ Z.lcm (Z.pred p) (Z.pred q)

(*
let factor ~e ~n =
  let xxx =
    let e,k,m = 100, 100, 100 in
    let p = Z.of_int 2 in
    let b = Nocrypto.Rng.Z.gen n in
    let g = ref 1 in
    let q = ref 1 in
    let it = ref (Z.of_int 2) in
    while (!g = 1) do
      let e = ((Z.numbits n) / (Z.numbits p)) + 1 in ();
    done
  in
  let prime_decomposition x =
    let rec inner c p =
      if Z.lt p (Z.sqrt c) then
        [p]
      else if Z.equal (Z.(mod) p c) Z.zero then
        c :: inner c (Z.div p c)
      else
        inner (Z.succ c) p
    in
    inner (Z.succ (Z.succ Z.zero)) x
  in
  let pub_exp = e in
  let modulus = n in
  let next_prime = ref (Z.sqrt modulus) in
  let removed = ref 0 in
  () (*while removed <> 0 do
    next_prime := Z.next_prime next_prime ;
    removed := Z.rem

  done*)
*)

let check_prime name zt =
  let pred_and_halved = Z.(div (pred zt) (of_int 2)) in (* (zt-1)/2 *)
  (*let four_p_minus_one = Z.(pred (mul zt (of_int 4))) in (* (4(zt)-1 *)*)
  let probab = Z.probab_prime pred_and_halved 25 in
  Logs.warn (fun m -> m "%s: probab: %d" name probab)

let cs_of_secret_key_asf asf =
  Logs.debug (fun m -> m "cs_of_secret_key_asf called") ;
  begin match asf with
    | Elgamal_privkey_asf {x} -> [x]
    | DSA_privkey_asf {Mirage_crypto_pk.Dsa.x ; _} -> [x]
    | RSA_privkey_asf {Mirage_crypto_pk.Rsa.d; p; q; e; n; _} ->
      (*Mirage_crypto_pk.Rsa.priv_of_primes ~e ~p:q ~q:p ;*)
      let whatever_d =
        Z.(d mod
           (div (mul (pred p) (pred q)) (succ one))) in
      check_prime "p" p ;
      check_prime "q" p ;
      (* TODO
let p_safe = Nocrypto.Numeric.pseudoprime Z.(div (pred p) (succ one)) in
      let q_safe = Nocrypto.Numeric.pseudoprime Z.(div (pred q) (succ one)) in
      *)
      let p_safe = false and q_safe = false in
      Logs.warn (fun m ->
          m "e: %a@.nocrypto-n:@,%a@,nocrypto-p:@,%a@,nocrypto-q:%a@,m-d:@,%a@,j-d:@,%a@,nocrypto-d:@,%a\
             @,p_safe: %a\
             @,q_safe: %a"
            pp_mpi e
            pp_mpi n
            pp_mpi p
            pp_mpi q
            pp_mpi whatever_d
            pp_mpi (rsa_d_secret_exponent ~e ~p ~q)
            pp_mpi d
            pp_bool p_safe
            pp_bool q_safe
        );

      [ rsa_d_secret_exponent ~e ~p ~q ; p; q; rsa_q_prime ~p ~q ]
  end
  |> cs_of_mpi_list

let serialize version {timestamp;algorithm_specific_data;_} =
  let buf = Cs.W.create 1024 in
  Cs.W.char buf (char_of_version version) ;
  (Cs.W.e_ptime32 (`Msg "serialize: e_ptime32") buf timestamp
   |> log_failed(fun m -> m "Error serializing timestamp %a" Ptime.pp timestamp)
   >>| fun _ ->
   Cs.W.char buf (char_of_public_key_algorithm
                    (public_key_algorithm_of_asf algorithm_specific_data))
  ) >>= fun () ->
  cs_of_public_key_asf algorithm_specific_data >>| Cs.W.cs buf >>| fun _ ->
  Cs.W.to_cs buf

let serialize_secret version sk =
  (* a secret key is the public key followed my the secret ASF MPIs: *)
  let buf = Cs.W.create 2000 in
  serialize version sk.public >>| Cs.W.cs buf >>= fun () ->
  (* One octet indicating string-to-key usage conventions.  Zero
     indicates that the secret-key data is not encrypted.  255 or 254
     indicates that a string-to-key specifier is being given.  Any
     other value is a symmetric-key encryption algorithm identifier.*)
  Cs.W.char buf '\x00' ;

  cs_of_secret_key_asf sk.priv_asf >>| fun asf ->
  Cs.W.cs buf asf ;

  (* - If the string-to-key usage octet is zero or 255, then a two-octet
       checksum of the plaintext of the algorithm-specific portion*)
  Cs.W.cs buf (Types.two_octet_checksum asf) ;

  Cs.W.to_cs buf

let hash_public_key t (hash_cb : Cs.t -> unit) : unit =
  let pk_body = serialize V4 t |> R.get_ok in
  let body_len = Cs.len pk_body in
  let buf = Cs.W.create (1 + 2  + body_len) in
  (* a.1) 0x99 (1 octet)*)
  Cs.W.char buf '\x99' ;

  (* a.2) high-order length octet of (b)-(e) (1 octet)*)
  (* a.3) low-order length octet of (b)-(e) (1 octet)*)
  Cs.W.cs buf (Cs.BE.create_uint16 body_len) ;

  (* b) version number = 4 (1 octet);
     c) timestamp of key creation (4 octets);
     d) algorithm (1 octet): 17 = DSA (example)
     e) Algorithm-specific fields.*)
  Cs.W.cs buf pk_body ;
  hash_cb (Cs.W.to_cs buf)

let v4_fingerprint t : Cs.t =
  (* RFC 4880: 12.2.  Key IDs and Fingerprints
   A V4 fingerprint is the 160-bit SHA-1 hash of the octet 0x99,
   followed by the two-octet packet length, followed by the entire
     Public-Key packet starting with the version field. *)
  let feed, final = digest_callback SHA1 |> R.get_ok in
  hash_public_key t feed ; final ()

let v4_key_id t : string  =
  (* in gnupg2 this is g10/keyid.c:fingerprint_from_pk*)
  (* The Key ID is the low-order 64 bits of the fingerprint.*)
  (* NOTE: "low-order" means rightmost since it's "big-endian".*)
  Cs.sub
    (v4_fingerprint t)
    (Mirage_crypto.Hash.SHA1.digest_size - (64/8))
    (64/8)
  |> R.get_ok |> Cs.to_string

let v4_key_id_hex t : string = Cs.to_hex (v4_key_id t |> Cs.of_string)

let parse_elgamal_asf buf : (public_key_asf * Cs.t, 'error) result =
  (*
     Algorithm Specific Fields for Elgamal encryption:
     - MPI of Elgamal (Diffie-Hellman) value g**k mod p.
     - MPI of Elgamal (Diffie-Hellman) value m * y**k mod p.*)
  consume_mpi buf >>= fun (p, buf) ->
  consume_mpi buf >>= fun (g,buf) ->
  consume_mpi buf >>= fun (y, buf_tl) ->
  (*y=g**x%p, where x is secret*)

  mpis_are_prime [p;g] >>| fun () ->
  Elgamal_pubkey_asf {p ; g ; y} , buf_tl

let parse_rsa_asf
    (purpose:[`Sign|`Encrypt|`Encrypt_or_sign])
    buf
  : (public_key_asf * Cs.t, [> `Msg of string ]) result =
  consume_mpi buf >>= fun (n, buf) ->
  consume_mpi buf >>= fun (e, buf_tl) ->
  mpis_are_prime [e] >>= fun () ->
  Mirage_crypto_pk.Rsa.pub ~e ~n >>| fun pk ->
  begin match purpose with
    | `Sign -> RSA_pubkey_sign_asf pk
    | `Encrypt -> RSA_pubkey_encrypt_asf pk
    | `Encrypt_or_sign -> RSA_pubkey_encrypt_or_sign_asf pk
  end , buf_tl

let parse_dsa_asf buf : (public_key_asf * Cs.t, 'error) result =
  consume_mpi buf >>= fun (p , buf) ->
  consume_mpi buf >>= fun (q , buf) ->
  consume_mpi buf >>= fun (gg , buf) ->
  consume_mpi buf >>= fun (y , buf_tl) ->

  (* TODO validation of gg and y? *)
  (* TODO Z.numbits gg *)
  (* TODO check y < p *)

  (* TODO the public key doesn't contain the hash algo; the signature does *)
  dsa_asf_are_valid_parameters ~p ~q ~hash_algo:SHA512 >>= fun () ->

  Mirage_crypto_pk.Dsa.pub ~p ~q ~gg ~y () >>| fun pk ->
  (DSA_pubkey_asf pk), buf_tl

let parse_secret_dsa_asf {Mirage_crypto_pk.Dsa.p;q;gg;y} buf
  : (private_key_asf * Cs.t, [> `Msg of string ] ) result =
  (* Algorithm-Specific Fields for DSA secret keys:
     - MPI of DSA secret exponent x. *)
  (* TODO validate parameters *)
  consume_mpi buf >>= fun (x,tl) ->
  Mirage_crypto_pk.Dsa.priv ~x ~p ~q ~gg ~y () >>| fun sk ->
  DSA_privkey_asf sk, tl

let parse_secret_elgamal_asf (_:'pk) buf =
  (* Algorithm-Specific Fields for Elgamal secret keys:
     - MPI of Elgamal secret exponent x. *)
  consume_mpi buf >>| fun (x, tl) ->
  Elgamal_privkey_asf {x}, tl

let parse_secret_rsa_asf
    ({Mirage_crypto_pk.Rsa.e; n}:Mirage_crypto_pk.Rsa.pub) buf
  : (private_key_asf * Cs.t, [> `Msg of string]) result =
  (* Algorithm-Specific Fields for RSA secret keys:
     - multiprecision integer (MPI) of RSA secret exponent d.
     - MPI of RSA secret prime value p.
     - MPI of RSA secret prime value q (p < q).
     - MPI of u, the multiplicative inverse of p, mod q. *)
  consume_mpi buf >>= fun (check_d, buf) -> (* "d" *)
  consume_mpi buf >>= fun (p, buf) ->
  consume_mpi buf >>= fun (q, buf) ->
  consume_mpi buf >>= fun (check_q', tl) ->
  (* "u" aka Mirage_crypto_pk.Rsa.priv.q' *)

  let sk_q_prime = rsa_q_prime ~p ~q in
  true_or_error (Z.equal check_q' sk_q_prime)
    (fun m -> m "RSA multiplicate inverse of p mod q is incorrect") >>= fun ()->

  let sk_d = rsa_d_secret_exponent ~e ~p ~q in
  true_or_error (Z.equal check_d sk_d)
    (fun m -> m "RSA secret exponent incorrect") >>= fun () ->

  Logs.warn (fun m -> m "SKIPPING RSA CHECK p < q BECAUSE ... well, nocrypto doesn't do that.");
(*  true_or_error (Z.compare p q < 0) (* verify p < q *)
    (fun m -> m "RSA secret key [%d]p >= [%d]q" (Z.numbits p) (Z.numbits q)
    ) >>= fun () ->*)

  mpis_are_prime [e;q;p] >>= fun () ->

  (*begin match Nocrypto.Rsa.priv_of_primes ~e ~q ~p with*)
  (*begin match Nocrypto.Rsa.priv_of_exp ?g ~e ~d:check_d n with*)
  begin match Mirage_crypto_pk.Rsa.priv_of_primes ~e ~q ~p with
    | Error _ as err -> err
    | exception _ -> Error (msg_of_invalid_mpi_parameters [e;p;q])
    | Ok sk -> (*TODO comparison p < q*)
      (* gpg --list-packets translation key:
         pkey[0] -> pk.n
         skey[2] -> check_d
         skey[3] -> sk.p
         skey[4] -> sk.q
         skey[5] -> Z.invert p q
      *)

      let whatever_d = let open Mirage_crypto_pk.Rsa in
        Z.(sk.d mod
           (div (mul (pred sk.p) (pred sk.q)) (succ one))) in
      Logs.warn (fun m ->
          m "e: %a@.n:@,%a@,p:@,%a@,q:%a@,whatever-d:@,%a@,expected-d:@,%a@,check-d:@,%a@,nocrypto-d:@,%a"
            pp_mpi sk.e
            pp_mpi sk.n
            pp_mpi sk.p
            pp_mpi sk.q
            pp_mpi whatever_d
            pp_mpi sk_d
            pp_mpi check_d
            pp_mpi sk.d
        );

      let open Mirage_crypto_pk.Rsa in
      (* validate key parameters; check "d" and "u"; "n"="p"*"q" *)
      true_or_error (Z.equal n sk.n
      (* TODO && Z.equal check_q' sk.q' && Z.equal check_d sk.d*) )
        (fun m -> m {|Inconsistent RSA secret key parameters read \
                      (d;q';computed.d;computed.q'):
                      {%a}
                      {pk.n = %a ; sk.p*s.q = %a } |}
            Fmt.(list ~sep:(unit "; ") pp_mpi) [check_d;check_q';sk.d;sk.q']
            pp_mpi n pp_mpi sk.n)
      >>| fun () -> (RSA_privkey_asf sk, tl)
  end

let parse_packet_return_extraneous_data (buf:Cs.t)
  : (t * Cs.t, [> `Msg of string]) result =
  Logs.debug (fun m -> m "%s parsing @[<v>%a@]" __LOC__
                 Cs.pp_hex buf) ;
  (* 1: '\x04' *)
  v4_verify_version buf >>= fun()->

  (* 4: key generation time *)
  Cs.BE.e_get_ptime32 `Incomplete_packet buf 1
  >>= fun timestamp ->

  (* 1: public key algorithm *)
  Cs.e_split_char ~start:5 `Incomplete_packet buf
  >>= fun (pk_algo_c , asf_cs) ->
  public_key_algorithm_of_char pk_algo_c
  |> log_failed (fun m -> m "Unknown public key algo when parsing PK") >>|

  (* MPIs / "Algorithm-Specific Fields" *)
  begin function
    | DSA -> parse_dsa_asf
    | Elgamal_encrypt_only -> parse_elgamal_asf
    | RSA_encrypt_or_sign -> parse_rsa_asf `Encrypt_or_sign
    | RSA_sign_only -> parse_rsa_asf `Sign
    | RSA_encrypt_only -> parse_rsa_asf `Encrypt
  end >>= fun parse_asf ->
  parse_asf asf_cs >>| fun (algorithm_specific_data, buf_tl) ->
  let temp = { timestamp ; algorithm_specific_data
             ; v4_fingerprint = Cs.create 0 } in
  {temp with
    v4_fingerprint = v4_fingerprint temp}, buf_tl

let parse_packet buf =
  parse_packet_return_extraneous_data buf >>= fun (pk,buf_tl) ->
  Cs.e_is_empty (`Msg "Public key contains extraneous data") buf_tl
  >>| fun () -> pk

let parse_secret_packet buf : (private_key, 'error) result =
  parse_packet_return_extraneous_data buf >>= fun (public,buf) ->
  Logs.debug (fun m -> m "got the public part of secret key") ;
  Cs.e_split_char `Incomplete_packet buf >>= fun (string_to_key, asf_cs) ->

  (* Make sure the secret key is not encrypted: *)
  e_char_equal (`Msg "Secret key is not unencrypted") '\x00' string_to_key
  >>| log_msg (fun m -> m "secret key not encrypted; good") >>= fun _ ->

  begin match public.algorithm_specific_data with
  | RSA_pubkey_sign_asf pk
  | RSA_pubkey_encrypt_asf pk
  | RSA_pubkey_encrypt_or_sign_asf pk -> parse_secret_rsa_asf pk asf_cs
  | Elgamal_pubkey_asf _ -> parse_secret_elgamal_asf () asf_cs
  | DSA_pubkey_asf pk -> parse_secret_dsa_asf pk asf_cs
  end
  >>= fun (priv_asf, checksum_tl) ->

  (* The "(sum octets) mod 65536" checksum: *)
  Cs.e_split `Incomplete_packet checksum_tl 2 >>= fun (csum, buf_tl) ->
  ( Cs.sub asf_cs 0 (Cs.len asf_cs - Cs.len checksum_tl)
    |> log_failed (fun m -> m "Error reading asf_portion")
    >>| fun asf_portion ->
    two_octet_checksum asf_portion
  ) >>= fun computed_sum ->
  true_or_error (Cs.equal computed_sum csum)
    (fun m -> m "Parsing secret key: Invalid mod-65536-checksum: %a <> %a"
        Cs.pp_hex csum Cs.pp_hex computed_sum
    ) >>| log_msg (fun m -> m "Parsing secret key: Good checksum: %a"
                      (pp_green Cs.pp_hex) csum) >>= fun () ->

  Cs.e_is_empty (`Msg "Extraneous data after secret ASF") buf_tl >>| fun () ->
  {public ; priv_asf }

let generate_new ?g ~(current_time:Ptime.t) key_type =
  begin match key_type with
  | DSA ->
    let priv = Mirage_crypto_pk.Dsa.generate ?g `Fips3072 in
    let pub  = Mirage_crypto_pk.Dsa.pub_of_priv priv in
    Ok (DSA_privkey_asf priv, DSA_pubkey_asf pub)
  | RSA_sign_only -> (* TODO warn about deprecated*)
    Logs.warn (fun m -> m "Generate sign-only RSA key deprecated in RFC 4880");
    let priv =
      Mirage_crypto_pk.Rsa.generate ?g ~e:(Z.of_int 65537) ~bits:4096 () in
    Ok (RSA_privkey_asf priv,
        RSA_pubkey_sign_asf (Mirage_crypto_pk.Rsa.pub_of_priv priv))
  | RSA_encrypt_or_sign ->
    let priv =
      Mirage_crypto_pk.Rsa.generate ?g ~e:(Z.of_int 65537) ~bits:4096 () in
    Ok (RSA_privkey_asf priv,
        RSA_pubkey_encrypt_or_sign_asf (Mirage_crypto_pk.Rsa.pub_of_priv priv))
  | RSA_encrypt_only ->
    Logs.warn (fun m -> m "Generate encrypt-only RSA key deprecated \
                           in RFC 4880");
    let priv =
      Mirage_crypto_pk.Rsa.generate ?g ~e:(Z.of_int 65537) ~bits:4096 () in
    Ok (RSA_privkey_asf priv,
        RSA_pubkey_encrypt_asf (Mirage_crypto_pk.Rsa.pub_of_priv priv))
  | Elgamal_encrypt_only ->
    error_msg (fun m -> m "Elgamal key generation not supported")
  end
  >>| fun (priv_asf,pub) ->
  let temp = {timestamp = current_time
             ; algorithm_specific_data = pub
             ; v4_fingerprint = Cs.create 0}
  in
  {public = {temp with
             v4_fingerprint = v4_fingerprint temp }
            ; priv_asf}

let public_of_private (priv_key : private_key) : t = priv_key.public

let can_sign t =
  (* TODO should also check the Key_usage_flags in the self-signature *)
  Logs.warn (fun m -> m "public_key_packet: can_sign: not considering KUF");
  match public_key_algorithm_of_asf t.algorithm_specific_data with
  | RSA_sign_only | RSA_encrypt_or_sign | DSA -> true
  | Elgamal_encrypt_only | RSA_encrypt_only -> false

let can_encrypt t =
  Logs.warn (fun m -> m "public_key_packet: can_encrypt: not considering KUF");
  match public_key_algorithm_of_asf t.algorithm_specific_data with
  | RSA_sign_only | DSA -> false
  | RSA_encrypt_or_sign | Elgamal_encrypt_only | RSA_encrypt_only -> true
