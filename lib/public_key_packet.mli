type public_key_asf = private
  | DSA_pubkey_asf of Mirage_crypto_pk.Dsa.pub
  | Elgamal_pubkey_asf of {p: Types.mpi ; g: Types.mpi; y: Types.mpi}
  | RSA_pubkey_sign_asf of Mirage_crypto_pk.Rsa.pub
  | RSA_pubkey_encrypt_asf of Mirage_crypto_pk.Rsa.pub
  | RSA_pubkey_encrypt_or_sign_asf of Mirage_crypto_pk.Rsa.pub

val public_key_algorithm_of_asf : public_key_asf -> Types.public_key_algorithm

type t = private {
  timestamp : Ptime.t ; (** Key creation timestamp *)
  algorithm_specific_data : public_key_asf ;
  v4_fingerprint : Cs.t (** SHA1 hash of the public key *)
}

type private_key_asf = private
  | DSA_privkey_asf of Mirage_crypto_pk.Dsa.priv
  | RSA_privkey_asf of Mirage_crypto_pk.Rsa.priv
  | Elgamal_privkey_asf of { x: Types.mpi}

type private_key = private {
  public : t ;
  priv_asf : private_key_asf
}

val pp : Format.formatter -> t -> unit
val pp_secret : Format.formatter -> private_key -> unit
val pp_pk_asf : Format.formatter -> public_key_asf -> unit

val hash_public_key : t -> (Cs.t -> unit) -> unit

type parse_error = [ `Incomplete_packet | `Msg of string ]

val parse_packet : Cs.t -> ( t, [> parse_error]) result

val parse_secret_packet : ?g:Mirage_crypto_rng.g -> Cs.t ->
  (private_key, [> parse_error] ) result

val serialize : Types.openpgp_version -> t -> (Cs.t,[> `Msg of string]) result

val serialize_secret : Types.openpgp_version -> private_key ->
  (Cs.t, [> `Msg of string]) result

val v4_key_id : t -> string

val v4_key_id_hex : t -> string

val can_sign : t -> bool
  (** [can_sign pk] is true if the algorithm is capable of signing.
      You should still check if the certification's Key_usage_flags
      allow signing.*)

val can_encrypt : t -> bool
  (** [can_encrypt pk] is true if the algorithm is capable of encryption.
      You should still check if the certification's Key_usage_flags
      allow encryption.*)


val generate_new : ?g:Mirage_crypto_rng.g ->
  current_time:Ptime.t ->
  Types.public_key_algorithm ->
  (private_key, [> `Msg of string ]) result

val public_of_private : private_key -> t
