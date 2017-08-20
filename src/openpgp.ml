open Rresult
open Types

(* TODO
   BEGIN PGP
       MESSAGE
       PRIVATE KEY BLOCK
       MESSAGE, PART X/Y
       MESSAGE, PART X
       SIGNATURE
*)

type packet_type =
  | Signature_packet of Signature_packet.t
  | Public_key_packet of Public_key_packet.t
  | Public_key_subpacket of Public_key_packet.t
  | Uid_packet of Uid_packet.t

let packet_tag_of_packet = begin function
  | Signature_packet _ -> Signature_tag
  | Public_key_packet _ -> Public_key_tag
  | Public_key_subpacket _ -> Public_key_subpacket_tag
  | Uid_packet _ -> Uid_tag
  end

let decode_ascii_armor (buf : Cstruct.t) =
  (* see https://tools.ietf.org/html/rfc4880#section-6.2 *)
  let max_length = 73 in (*maximum line length *)

  begin match Cs.next_line ~max_length buf with
    | `Next_tuple pair -> Ok pair
    | `Last_line _ -> Error `Invalid
  end
  >>= fun (begin_header, buf) ->

  (* check that it starts with a -----BEGIN... *)
  Cs.e_split `Invalid begin_header (String.length "-----BEGIN PGP ")
  >>= fun (begin_pgp, begin_tl) ->
  Cs.e_equal_string `Invalid "-----BEGIN PGP " begin_pgp >>= fun () ->

  (* check that it ends with five dashes: *)
  Cs.e_split `Invalid begin_tl (Cs.len begin_tl -5)
  >>= fun (begin_type , begin_tl) ->
  Cs.e_equal_string `Invalid "-----" begin_tl >>= fun () ->

  (* check that we know how to handle this type of ascii-armored message: *)
  begin match Cs.to_string begin_type with
      | "PUBLIC KEY BLOCK" -> Ok Ascii_public_key_block
      | "SIGNATURE" -> Ok Ascii_signature
      | _ -> Error `Invalid_key_type (*TODO better error*)
  end
  >>= fun pkt_type ->

  (* skip additional headers (like "Version:") *)
  let rec skip_headers buf_tl =
    begin match Cs.next_line ~max_length buf_tl  with
      | `Last_line _ -> Error `Missing_body
      | `Next_tuple pair -> Ok pair
    end
    >>= fun (header,buf_tl) ->
    if Cs.len header = 0 then
      R.ok buf_tl
    else
      (* skip to next*)
      let()= Logs.debug (fun m -> m "Skipping header: %S" (Cs.to_string header)) in
      skip_headers buf_tl
  in
  skip_headers buf
  >>= fun body ->

  let rec decode_body acc tl : (Cs.t*Cs.t,[> `Invalid]) result =
    let b64_decode cs =
      Nocrypto.Base64.decode cs
      |> R.of_option ~none:(fun()-> Error `Invalid)
    in
    begin match Cs.next_line ~max_length:73 tl with
      | `Last_line _ -> R.error `Invalid (*TODO better error*)
      | `Next_tuple (cs,tl) when Some 0 = Cs.index_opt cs '=' ->
        (* the CRC-24 starts with an =-sign *)
        Cs.e_split ~start:1 `Invalid cs 4
        >>= fun (b64,must_be_empty) ->
        if Cs.len must_be_empty <> 0 then Error `Invalid
        else
        b64_decode b64 >>= fun target_crc ->
        let()= Logs.debug (fun m -> m "target crc: %s" (Cs.to_hex target_crc))in
        begin match List.rev acc |> Cs.concat with
          | decoded when Cs.equal target_crc (crc24 decoded) ->
            Ok (decoded, tl)
          | _ -> Error `Invalid_crc24
        end
      | `Next_tuple (cs,tl) ->
        b64_decode cs >>= fun decoded ->
        decode_body (decoded::acc) tl
    end
  in decode_body [] body
  >>= fun (decoded, buf) ->

  (* Now we should be at the last line. *)
  begin match Cs.next_line ~max_length buf with
    | `Next_tuple ok -> Ok ok
    | `Last_line cs -> Ok (cs, Cs.create 0)
  end
  >>= fun (end_line, buf) ->
  Cs.e_find_string_list `Invalid ["\n";"\r\n";""] buf
  >>= fun _ ->

  begin match pkt_type with
  | Ascii_public_key_block ->
    Cs.e_equal_string `Missing_end_block "-----END PGP PUBLIC KEY BLOCK-----" end_line
  | Ascii_signature ->
    Cs.e_equal_string `Missing_end_block "-----END PGP SIGNATURE-----" end_line
  | Ascii_private_key_block
  | Ascii_message
  | Ascii_message_part_x _
  | Ascii_message_part_x_of_y _ ->
     Error `Malformed (* TODO `Not_implemented *)
  end
  >>= fun () ->
  Ok (pkt_type, decoded)

let parse_packet packet_tag pkt_body : (packet_type,'error) result =
  begin match packet_tag with
    | Public_key_tag ->
      Public_key_packet.parse_packet pkt_body
      >>| fun pkt -> Public_key_packet pkt
    | Public_key_subpacket_tag ->
      Public_key_packet.parse_packet pkt_body
      >>| fun pkt -> Public_key_subpacket pkt
    | Uid_tag ->
      Uid_packet.parse_packet pkt_body
      >>| fun pkt -> Uid_packet pkt
    | Signature_tag ->
      Signature_packet.parse_packet pkt_body
      >>| fun pkt -> Signature_packet pkt
    | Secret_key_tag
    | Secret_subkey_packet_tag
    | User_attribute_tag ->
      R.error (`Unimplemented_algorithm 'P') (*TODO should have it's own (`Unimplemented of [`Algorithm of char | `Tag of char | `Version of char])*)
  end

let next_packet (full_buf : Cs.t) :
  ((packet_tag_type * Cs.t * Cs.t) option,
   [>`Invalid_packet
   | `Unimplemented_feature of string
   | `Incomplete_packet]) result =
  if Cs.len full_buf = 0 then Ok None else
  consume_packet_header full_buf
  |> R.reword_error (function
      |`Incomplete_packet as i -> i
      |`Invalid_packet_header -> `Invalid_packet)
  >>= begin function
  | { length_type ; packet_tag; _ } , pkt_header_tl ->
    consume_packet_length length_type pkt_header_tl
    |> R.reword_error (function
        | `Invalid_length -> `Invalid_packet
        | `Incomplete_packet as i -> i
        | `Unimplemented_feature_partial_length ->
      `Unimplemented_feature "partial length")
      >>= fun (pkt_body, next_packet) ->
      Ok (Some (packet_tag , pkt_body, next_packet))
  end

let parse_packet_bodies parser body_lst =
  List.fold_left (fun acc -> fun (cs:Cs.t) ->
            acc >>= fun acc ->
            parser cs >>= fun parsed ->
            R.ok (parsed::acc)
    ) (Ok []) body_lst

let parse_packets cs : (('ok * Cs.t) list, int * 'error) result =
  (* TODO: 11.1.  Transferable Public Keys *)
  let rec loop acc cs_tl =
    next_packet cs_tl
    |> R.reword_error (fun a -> cs_tl.Cstruct.off, a)
    >>= begin function
      | Some (packet_type , pkt_body, next_tl) ->
        (parse_packet packet_type pkt_body
        |> R.reword_error (fun e -> List.length acc , e))
        >>= fun parsed ->
        loop ((parsed,pkt_body)::acc) next_tl
      | None ->
        R.ok (List.rev acc)
    end
  in
  loop [] cs

module Signature =
struct
  include Signature_packet

  type uid =
    { uid : Uid_packet.t
    ; certifications : Signature_packet.t list
    }

  type user_attribute =
    { certifications : Signature_packet.t list
      (* : User_attribute_packet.t *)
    }

  type subkey =
    { key : Public_key_packet.t
    ; signature : Signature_packet.t
    (* plus optionally a revocation signatures *)
    ; revocation : Signature_packet.t option
    }

  type transferable_public_key =
    {
    (* One Public-Key packet *)
      root_key : Public_key_packet.t
      (* Zero or more revocation signatures *)
      ; revocations : Signature_packet.t list
    (* One or more User ID packets *)
    ; uids : uid list
    (* Zero or more User Attribute packets *)
    ; user_attributes : user_attribute list
    (* Zero or more subkey packets *)
    ; subkeys : subkey list
    }

  let root_pk_of_packets (* TODO aka root_key_of_packets *)
    (packets : (packet_tag_type * Cs.t) list)
  : (transferable_public_key * (packet_tag_type * Cs.t) list,
   [> `Extraneous_packets_after_signature
   | `Incomplete_packet
   | `Invalid_packet
   | `Invalid_length
   | `Unimplemented_feature_partial_length
   | `Invalid_signature
   | `Unimplemented_version of char
   | `Unimplemented_algorithm of char
   | `Invalid_mpi_parameters of Types.mpi list
   ]
  ) result
  =
  (* RFC 4880: 11.1 Transferable Public Keys *)
  (* this function imports the output of gpg --export *)

  (* this would be a good place to wonder what kind of crack the spec people smoked while writing 5.2.4: Computing Signatures...*)

  let debug_packets packets =
    (* TODO learn how to make pretty printers *)
    Logs.debug (fun m ->
        m "Amount of packets: %d\n|  %s\n"
          (List.length packets)
          (packets|>List.map (fun (tag,cs)->
               (string_of_packet_tag_type tag) ^" "
               ^ (begin match Signature_packet.parse_packet cs with
                   | Error _ -> ""
                   | Ok s -> string_of_signature_type s.signature_type
                 end)
               ^" : "^ (string_of_int (Cs.len cs))
             )
           |> String.concat "\n|  ")
      )
  in

  let debug_if_any s = begin function
      | [] -> ()
      | lst ->
        Logs.debug (fun m -> m ("%s: %d") s (List.length lst));
  end
  in

  let () = debug_packets packets in
  (* RFC 4880: - One Public-Key packet: *)
  begin match packets with
    | (Public_key_tag, pub_cs)::tl ->
      R.ok (pub_cs, tl)
    | _ -> R.error `Invalid_signature
  end
  >>= fun (root_pub_cs , packets) ->

    (* check that the root public key in the input matches
       the expected public key.
       In GnuPG they check the keyid (64bits of the SHA1). In some cases. Sometimes they don't check at all.
       (gnupg2/g10/sig-check.c:check_key_signature2 if feel like MiTM'ing some package managers)
       We compare the public key MPI data.
       In contrast we don't check the timestamp.
       Pick your poison.
    *)
    Public_key_packet.parse_packet root_pub_cs
    |> R.reword_error (function _ -> `Invalid_signature)
    >>= fun root_pk ->

    (* TODO verify expiry date*)

    (* TODO extract version from the root_pk and make sure the remaining packets use the same version *)

    let find_sig_pair (needle_one:packet_tag_type) (haystack:(packet_tag_type*Cs.t)list) =
    (* finds pairs (needle_one, needle_two) at the head of haystack
       if needle_two is None, it ignored
*)
      list_find_leading_pairs
        (fun (tag1,cs1) -> fun (tag2,cs2) ->
           if tag1 = needle_one && tag2 = Signature_tag
           then R.ok (cs1,cs2)
           else R.error `Invalid_packet
        ) haystack
    in

    let pair_must_be tag = function
      | (t,cs) when t = tag -> Ok cs
      | _ -> Error `Invalid_packet
    in
    let sig_is_type typ s =
      if s.signature_type = typ
      then R.ok s
      else R.error `Invalid_packet
    in

    list_find_leading (pair_must_be Signature_tag) packets
    >>= parse_packet_bodies parse_packet
    >>= list_find_leading (sig_is_type Key_revocation_signature)
    >>= fun revocation_signatures ->
    list_drop_e_n `Invalid_packet
      (List.length revocation_signatures) packets
    >>= fun packets ->
  (* TODO RFC 4880: - Zero or more revocation signatures: *)
  (* revocation keys are detailed here:
     https://tools.ietf.org/html/rfc4880#section-5.2.3.15 *)
  (* TODO check revocation signatures *)

    (* RFC 4880: - One or more User ID packets: *)
  (*Immediately following each User ID packet, there are zero or more
   Signature packets.  Each Signature packet is calculated on the
   immediately preceding User ID packet and the initial Public-Key
    packet.*)
    (* TODo (followed by zero or more signature packets) -- we fail if there are unsigned Uids - design feature? *)
    find_sig_pair Uid_tag packets
    >>= fun uids_and_sigs ->
    debug_if_any "uids and sigs" uids_and_sigs;
    let uids_count = List.length uids_and_sigs in
    if uids_count = 0 || uids_count > 1000
    then R.error `Invalid_packet
    else R.ok packets
    >>= list_drop_e_n `Invalid_packet (2*uids_count)
    >>= fun packets ->
    let rec check_uids_and_sigs acc =
      begin function
        | (uid_cs,sig_cs)::tl ->
          Uid_packet.parse_packet uid_cs >>= fun uid ->
          Signature_packet.parse_packet sig_cs >>= fun signature ->
          (* check signature.signature_type: *)
          begin match signature.signature_type with
            | Generic_certification_of_user_id_and_public_key_packet
            | Persona_certification_of_user_id_and_public_key_packet
            | Casual_certification_of_user_id_and_public_key_packet
            | Positive_certification_of_user_id_and_public_key_packet
              -> R.ok()
            |_ -> R.error `Invalid_signature
          end
          >>= fun () ->
          (* set up hashing with this signature: *)
          let (hash_cb, hash_final) =
            Signature_packet.digest_callback signature.hash_algorithm

          in
          (* TODO handle version V3 *)
          let () = Public_key_packet.(hash_cb |> (serialize V4 root_pk |> hash_public_key)) in
          let () = Uid_packet.hash uid hash_cb V4 in
          construct_to_be_hashed_cs signature
          >>= fun tbh ->
          let()= hash_cb tbh in
          check_signature root_pk
            signature.hash_algorithm hash_final signature
          |> R.reword_error (function err ->
              Logs.debug (fun m -> m "signature check failed on a uid sig"); err)
          >>= fun _ ->
          check_uids_and_sigs ({uid; certifications = [signature]}::acc) tl
        | [] -> R.ok (List.rev acc)
      end
    in
    check_uids_and_sigs [] uids_and_sigs >>= fun verified_uids ->

    find_sig_pair User_attribute_tag packets
    >>= fun user_attributes_and_sigs ->
    list_drop_e_n `Invalid_packet (List.length user_attributes_and_sigs) packets
    >>= fun packets ->

    (* TODO check user_attributes *)

    debug_if_any "user_attributes" user_attributes_and_sigs ;

    (* TODO technically these (pk subpackets) can be followed by revocation signatures; we don't handle that *)
    find_sig_pair Public_key_subpacket_tag packets
    >>= fun subkeys_and_sigs ->
    let subkeys_and_sigs_length = List.length subkeys_and_sigs in
    if subkeys_and_sigs_length > 1000 then
      R.error `Invalid_packet
    else
    list_drop_e_n `Invalid_packet (subkeys_and_sigs_length*2) packets >>= fun packets ->

    debug_if_any "subkeys_and_sigs" subkeys_and_sigs ;

    let rec check_subkeys_and_sigs acc =
      begin function
        | (subkey_cs,sig_cs)::tl ->
          Public_key_packet.parse_packet subkey_cs
          >>= fun subkey ->
          Signature_packet.parse_packet sig_cs
          >>= fun signature ->
          begin match signature.signature_type with
            | Subkey_binding_signature ->
              R.ok ()
            | _ ->
              R.error `Invalid_packet
          end >>= fun () ->

          (* RFC 4880: 0x18: Subkey Binding Signature
       This signature is a statement by the top-level signing key that
             indicates that it owns the subkey.*)

          (* set up hashing with this signature: *)
          let (hash_cb, hash_final) =
            Signature_packet.digest_callback signature.hash_algorithm
          in

          (* This signature is calculated directly on the
             primary key and subkey, and not on any User ID or other packets.*)
          Public_key_packet.hash_public_key root_pub_cs hash_cb ;
          Public_key_packet.hash_public_key subkey_cs hash_cb ;

          (* A signature that binds a signing subkey MUST have
       an Embedded Signature subpacket in this binding signature that
       contains a 0x19 signature made by the signing subkey on the
             primary key and subkey: *)

          (* TODO implement checking of Embedded Signature subpackets.
              for now we just reject: *)
          begin match subkey.Public_key_packet.algorithm_specific_data with
            | Public_key_packet.RSA_pubkey_encrypt_asf _
            | Public_key_packet.Elgamal_pubkey_asf _ -> R.ok ()
            | Public_key_packet.RSA_pubkey_sign_asf _
            | Public_key_packet.RSA_pubkey_encrypt_or_sign_asf _
            | Public_key_packet.DSA_pubkey_asf _ ->
              Logs.debug (fun m -> m "TODO this signature binds a signing subkey. it must have an Embedded Signature subpacket that contains a 0x19 signature made by the signing subkey on the primary key and subkey to prevent a person from stealing other people's keys. this is not implemented, so for safety reasons we reject it. sorry.");
              Error (`Unimplemented_algorithm
                       (char_of_public_key_algorithm DSA))
          end
          >>= fun () ->

          construct_to_be_hashed_cs signature
          >>= fun tbh -> let () = hash_cb tbh in
          check_signature root_pk signature.hash_algorithm
            hash_final signature
          >>= fun _ -> check_subkeys_and_sigs
                       ({key = subkey; signature; revocation = None}::acc) tl
        | [] -> R.ok (List.rev acc)
      end
    in
    check_subkeys_and_sigs [] subkeys_and_sigs >>= fun verified_subkeys ->

    (* Final check: *)
    (* TODO if List.length packets <> 0 then begin
      debug_packets packets ;
      R.error `Extraneous_packets_after_signature
    end else *)
       R.ok ({
         root_key = root_pk
       ; revocations = [] (* TODO *)
       ; uids = verified_uids
       ; user_attributes = [] (* TODO *)
       ; subkeys = verified_subkeys
       }, packets)
    (* one byte version
       | V3 -> 4 bytes timestamp
       | V4 -> pk algo, hash algo, two bytes len of sig->hashed, version, 0xff, len of all this data hashed
    *)
  (* TODO should implement signature target subpacket parsing*)
  (* RFC 4880 5.2.4: Computing Signatures:
When a signature is made over a key, the hash data starts with the
   octet 0x99, followed by a two-octet length of the key, and then body
   of the key packet.  (Note that this is an old-style packet header for
   a key packet with two-octet length.)  A subkey binding signature
   (type 0x18) or primary key binding signature (type 0x19) then hashes
   the subkey using the same format as the main key (also using 0x99 as
   the first octet).  Key revocation signatures (types 0x20 and 0x28)
       hash only the key being revoked. *)


  (* TODO RFC 4880: - Zero or more User Attribute packets: *)
  (* RFC 4880: Zero or more Subkey packets *)
end
