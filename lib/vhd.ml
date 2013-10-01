(*
 * Copyright (C) 2011-2013 Citrix Inc
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)


(* VHD manipulation *)

let sector_size = 512
let sector_shift = 9

exception Cstruct_differ

let cstruct_equal a b =
  let check_contents a b =
    try
      for i = 0 to Cstruct.len a - 1 do
        let a' = Cstruct.get_char a i in
        let b' = Cstruct.get_char b i in
        if a' <> b' then raise Cstruct_differ
      done;
      true
    with _ -> false in
  (Cstruct.len a = (Cstruct.len b)) && (check_contents a b)

exception Invalid_sector of int64 * int64

module Int64 = struct
  include Int64
  let ( ++ ) = add
  let ( -- ) = sub
  let ( // ) = div
  let ( ** ) = mul
  let ( lsl ) = shift_left
  let ( lsr ) = shift_right_logical

  let roundup_sector x = ((x ++ (1L lsl sector_shift -- 1L)) lsr sector_shift) lsl sector_shift
end

let roundup_sector x = ((x + (1 lsl sector_shift - 1)) lsr sector_shift) lsl sector_shift

let kib = 1024L
let mib = Int64.(1024L ** kib)
let gib = Int64.(1024L ** mib)
let max_disk_size = Int64.(2040L ** gib)

let kib_shift = 10
let mib_shift = 20
let gib_shift = 30

let blank_uuid = match Uuidm.of_bytes (String.make 16 '\000') with
  | Some x -> x
  | None -> assert false (* never happens *)

module Feature = struct
  type t = 
    | Temporary

  let of_int32 x =
    if Int32.logand x 1l <> 0l then [ Temporary ] else []

  let to_int32 ts =
    let one = function
      | Temporary -> 1 in
    let reserved = 2 in (* always set *)
    Int32.of_int (List.fold_left (lor) reserved (List.map one ts))

  let to_string = function
    | Temporary -> "Temporary"
end

module Disk_type = struct
  type t = 
    | Fixed_hard_disk
    | Dynamic_hard_disk
    | Differencing_hard_disk

  exception Unknown of int32

  let of_int32 =
    let open Vhd_result in function
    | 2l -> return Fixed_hard_disk 
    | 3l -> return Dynamic_hard_disk
    | 4l -> return Differencing_hard_disk
    | x -> fail (Unknown x)

  let to_int32 = function
    | Fixed_hard_disk -> 2l
    | Dynamic_hard_disk -> 3l
    | Differencing_hard_disk -> 4l

  let to_string = function
    | Fixed_hard_disk -> "Fixed_hard_disk"
    | Dynamic_hard_disk -> "Dynamic_hard_disk"
    | Differencing_hard_disk -> "Differencing_hard_disk"

end

module Host_OS = struct
  type t =
    | Windows
    | Macintosh
    | Other of int32

  let of_int32 = function
    | 0x5769326bl -> Windows
    | 0x4d616320l -> Macintosh
    | x -> Other x

  let to_int32 = function
    | Windows -> 0x5769326bl
    | Macintosh -> 0x4d616320l
    | Other x -> x

  let to_string = function
    | Windows -> "Windows"
    | Macintosh -> "Macintosh"
    | Other x -> Printf.sprintf "Other %lx" x
end

module Geometry = struct
  type t = {
    cylinders : int;
    heads : int;
    sectors : int;
  }

  (* from the Appendix 'CHS calculation' *)
  let of_sectors sectors =
    let open Int64 in
    let max_secs = 65535L ** 255L ** 16L in
    let secs = min max_secs sectors in

    let secs_per_track = ref 0L in
    let heads = ref 0L in
    let cyls_times_heads = ref 0L in
  
    if secs > 65535L ** 63L ** 16L then begin
      secs_per_track := 255L;
      heads := 16L;
      cyls_times_heads := secs // !secs_per_track;
    end else begin
      secs_per_track := 17L;
      cyls_times_heads := secs // !secs_per_track;

      heads := max ((!cyls_times_heads ++ 1023L) // 1024L) 4L;

      if (!cyls_times_heads >= (!heads ** 1024L) || !heads > 16L) then begin
        secs_per_track := 31L;
        heads := 16L;
        cyls_times_heads := secs // !secs_per_track;
      end;

      if (!cyls_times_heads >= (!heads ** 1024L)) then begin
        secs_per_track := 63L;
        heads := 16L;
        cyls_times_heads := secs // !secs_per_track;
      end	    
    end;
    { cylinders = to_int (!cyls_times_heads // !heads); heads = to_int !heads; sectors = to_int !secs_per_track }

  let to_string t = Printf.sprintf "{ cylinders = %d; heads = %d; sectors = %d }"
    t.cylinders t.heads t.sectors

end

module Checksum = struct
  type t = int32

  (* TODO: use the optimised mirage version *)
  let of_cstruct m =
    let rec inner n cur =
      if n=Cstruct.len m then cur else
        inner (n+1) (Int32.add cur (Int32.of_int (Cstruct.get_uint8 m n)))
    in 
    Int32.lognot (inner 0 0l)

  let sub_int32 t x =
    (* Adjust the checksum [t] by removing the contribution of [x] *)
    let open Int32 in
    let t' = lognot t in
    let a = logand (shift_right_logical x 0) (of_int 0xff) in
    let b = logand (shift_right_logical x 8) (of_int 0xff) in
    let c = logand (shift_right_logical x 16) (of_int 0xff) in
    let d = logand (shift_right_logical x 24) (of_int 0xff) in
    Int32.lognot (sub (sub (sub (sub t' a) b) c) d)
end

module UTF16 = struct
  type t = int array

  let to_utf8_exn s =
    let utf8_chars_of_int i = 
      if i < 0x80 then [char_of_int i] 
      else if i < 0x800 then 
        begin
          let z = i land 0x3f
          and y = (i lsr 6) land 0x1f in 
          [char_of_int (0xc0 + y); char_of_int (0x80+z)]
        end
      else if i < 0x10000 then
        begin
          let z = i land 0x3f
          and y = (i lsr 6) land 0x3f 
          and x = (i lsr 12) land 0x0f in
          [char_of_int (0xe0 + x); char_of_int (0x80+y); char_of_int (0x80+z)]
        end
      else if i < 0x110000 then
        begin
          let z = i land 0x3f
          and y = (i lsr 6) land 0x3f
          and x = (i lsr 12) land 0x3f
          and w = (i lsr 18) land 0x07 in
          [char_of_int (0xf0 + w); char_of_int (0x80+x); char_of_int (0x80+y); char_of_int (0x80+z)]
        end
      else
        failwith "Bad unicode character!" in
    String.concat "" (List.map (fun c -> Printf.sprintf "%c" c) (List.flatten (List.map utf8_chars_of_int (Array.to_list s))))

  let to_utf8 x =
    try
      Vhd_result.Ok (to_utf8_exn x)
    with e ->
      Vhd_result.Error e

  let to_string x = Printf.sprintf "[| %s |]" (String.concat "; " (List.map string_of_int (Array.to_list x)))

  let of_ascii string =
    Array.init (String.length string)
      (fun c -> int_of_char string.[c])

  let of_utf8 = of_ascii (* FIXME (obviously) *)

  let marshal (buf: Cstruct.t) t =
    let rec inner ofs n =
      if n = Array.length t
      then Cstruct.sub buf 0 ofs
      else begin
        let char = t.(n) in
        if char < 0x10000 then begin
          Cstruct.BE.set_uint16 buf ofs char;
          inner (ofs + 2) (n + 1)
        end else begin
          let char = char - 0x10000 in
          let c1 = (char lsr 10) land 0x3ff in (* high bits *)
          let c2 = char land 0x3ff in (* low bits *)
          Cstruct.BE.set_uint16 buf (ofs + 0) (0xd800 + c1);
          Cstruct.BE.set_uint16 buf (ofs + 2) (0xdc00 + c2);
          inner (ofs + 4) (n + 1)
        end
      end in
    inner 0 0

  let unmarshal (buf: Cstruct.t) len =
    (* Check if there's a byte order marker *)
    let bigendian, pos, max = match Cstruct.BE.get_uint16 buf 0 with
      | 0xfeff -> true,  2, (len / 2 - 1)
      | 0xfffe -> false, 2, (len / 2 - 1)
      | _      -> true,  0, (len / 2) in

    (* UTF-16 strings end with a \000\000 *)
    let rec strlen acc i =
      if i >= max then acc
      else
        if Cstruct.BE.get_uint16 buf i = 0
        then acc
        else strlen (acc + 1) (i + 2) in

    let max = strlen 0 0 in
    let string = Array.create max 0 in

    let rec inner ofs n =
      if n >= max then string
      else begin
        let c = Cstruct.BE.get_uint16 buf ofs in
        let code, ofs', n' =
          if c >= 0xd800 && c <= 0xdbff then begin
            let c2 = Cstruct.BE.get_uint16 buf (ofs + 2) in
            if c2 < 0xdc00 || c2 > 0xdfff then (failwith (Printf.sprintf "Bad unicode char: %04x %04x" c c2));
            let top10bits = c-0xd800 in
            let bottom10bits = c2-0xdc00 in
            let char = 0x10000 + (bottom10bits lor (top10bits lsl 10)) in
            char, ofs + 4, n + 1
          end else c, ofs + 2, n + 1 in
        string.(n) <- code;
        inner ofs' n'
      end in
    try
      Vhd_result.Ok (inner pos 0)
    with e ->
      Vhd_result.Error e
end

module Footer = struct
  type t = {
    (* "conectix" *)
    features : Feature.t list;
    data_offset : int64;
    time_stamp : int32;
    creator_application : string;
    creator_version : int32;
    creator_host_os : Host_OS.t;
    original_size : int64;
    current_size : int64;
    geometry : Geometry.t;
    disk_type : Disk_type.t;
    checksum : int32;
    uid : Uuidm.t;
    saved_state : bool
  }

  let default_creator_application = "caml"
  let default_creator_version = 0x00000001l

  let create ?(features=[]) ~data_offset ?(time_stamp=0l)
    ?(creator_application = default_creator_application)
    ?(creator_version = default_creator_version)
    ?(creator_host_os = Host_OS.Other 0l)
    ~current_size ?original_size
    ~disk_type
    ?(uid = Uuidm.create `V4) ?(saved_state = false) () =
  let original_size = match original_size with
    | None -> current_size
    | Some x -> x in
  let geometry = Geometry.of_sectors Int64.(current_size lsr sector_shift) in
  let checksum = 0l in
  { features; data_offset; time_stamp; creator_application;
    creator_version; creator_host_os; original_size;
    current_size; geometry; disk_type; checksum; uid; saved_state }

  let to_string t = Printf.sprintf "{ features = [ %s ]; data_offset = %Lx; time_stamp = %lx; creator_application = %s; creator_version = %lx; creator_host_os = %s; original_size = %Ld; current_size = %Ld; geometry = %s; disk_type = %s; checksum = %ld; uid = %s; saved_state = %b }"
    (String.concat "; " (List.map Feature.to_string t.features)) t.data_offset t.time_stamp
    t.creator_application t.creator_version (Host_OS.to_string t.creator_host_os)
    t.original_size t.current_size (Geometry.to_string t.geometry) (Disk_type.to_string t.disk_type)
    t.checksum (Uuidm.to_string t.uid) t.saved_state

  let magic = "conectix"

  let expected_version = 0x00010000l

  let dump t =
    Printf.printf "VHD FOOTER\n";
    Printf.printf "-=-=-=-=-=\n\n";
    Printf.printf "cookie              : %s\n" magic;
    Printf.printf "features            : %s\n" (String.concat "," (List.map Feature.to_string t.features));
    Printf.printf "format_version      : 0x%lx\n" expected_version;
    Printf.printf "data_offset         : 0x%Lx\n" t.data_offset;
    Printf.printf "time_stamp          : %lu\n" t.time_stamp;
    Printf.printf "creator_application : %s\n" t.creator_application;
    Printf.printf "creator_version     : 0x%lx\n" t.creator_version;
    Printf.printf "creator_host_os     : %s\n" (Host_OS.to_string t.creator_host_os);
    Printf.printf "original_size       : 0x%Lx\n" t.original_size;
    Printf.printf "current_size        : 0x%Lx\n" t.current_size;
    Printf.printf "geometry            : %s\n" (Geometry.to_string t.geometry);
    Printf.printf "disk_type           : %s\n" (Disk_type.to_string t.disk_type);
    Printf.printf "checksum            : %lu\n" t.checksum;
    Printf.printf "uid                 : %s\n" (Uuidm.to_string t.uid);
    Printf.printf "saved_state         : %b\n\n" t.saved_state

  cstruct footer {
    uint8_t magic[8];
    uint32_t features;
    uint32_t version;
    uint64_t data_offset;
    uint32_t time_stamp;
    uint8_t creator_application[4];
    uint32_t creator_version;
    uint32_t creator_host_os;
    uint64_t original_size;
    uint64_t current_size;
    uint16_t cylinders;
    uint8_t heads;
    uint8_t sectors;
    uint32_t disk_type;
    uint32_t checksum;
    uint8_t uid[16];
    uint8_t saved_state
    (* 427 zeroed *)
  } as big_endian

  let sizeof = 512

  let marshal (buf: Cstruct.t) t =
    set_footer_magic magic 0 buf;
    set_footer_features buf (Feature.to_int32 t.features);
    set_footer_version buf expected_version;
    set_footer_data_offset buf t.data_offset;
    set_footer_time_stamp buf t.time_stamp;
    set_footer_creator_application t.creator_application 0 buf;
    set_footer_creator_version buf t.creator_version;
    set_footer_creator_host_os buf (Host_OS.to_int32 t.creator_host_os);
    set_footer_original_size buf t.original_size;
    set_footer_current_size buf t.current_size;
    set_footer_cylinders buf t.geometry.Geometry.cylinders;
    set_footer_heads buf t.geometry.Geometry.heads;
    set_footer_sectors buf t.geometry.Geometry.sectors;
    set_footer_disk_type buf (Disk_type.to_int32 t.disk_type);
    set_footer_checksum buf 0l;
    set_footer_uid (Uuidm.to_bytes t.uid) 0 buf;
    set_footer_saved_state buf (if t.saved_state then 1 else 0);
    let remaining = Cstruct.shift buf sizeof_footer in
    for i = 0 to 426 do
      Cstruct.set_uint8 remaining i 0
    done;
    let checksum = Checksum.of_cstruct (Cstruct.sub buf 0 sizeof) in
    set_footer_checksum buf checksum;
    { t with checksum }

  let unmarshal (buf: Cstruct.t) =
    let open Vhd_result in
    let magic' = copy_footer_magic buf in
    ( if magic' <> magic
      then fail (Failure (Printf.sprintf "Unsupported footer cookie: expected %s, got %s" magic magic'))
      else return () ) >>= fun () ->
    let features = Feature.of_int32 (get_footer_features buf) in
    let format_version = get_footer_version buf in
    ( if format_version <> expected_version
      then fail (Failure (Printf.sprintf "Unsupported footer version: expected %lx, got %lx" expected_version format_version))
      else return () ) >>= fun () ->
    let data_offset = get_footer_data_offset buf in
    let time_stamp = get_footer_time_stamp buf in
    let creator_application = copy_footer_creator_application buf in
    let creator_version = get_footer_creator_version buf in
    let creator_host_os = Host_OS.of_int32 (get_footer_creator_host_os buf) in
    let original_size = get_footer_original_size buf in
    let current_size = get_footer_current_size buf in
    let cylinders = get_footer_cylinders buf in
    let heads = get_footer_heads buf in
    let sectors = get_footer_sectors buf in
    let geometry = { Geometry.cylinders; heads; sectors } in
    Disk_type.of_int32 (get_footer_disk_type buf) >>= fun disk_type ->
    let checksum = get_footer_checksum buf in
    let bytes = copy_footer_uid buf in
    ( match Uuidm.of_bytes bytes with
      | None -> fail (Failure (Printf.sprintf "Failed to decode UUID: %s" (String.escaped bytes)))
      | Some uid -> return uid ) >>= fun uid ->
    let saved_state = get_footer_saved_state buf = 1 in
    let expected_checksum = Checksum.(sub_int32 (of_cstruct (Cstruct.sub buf 0 sizeof)) checksum) in
    ( if checksum <> expected_checksum
      then fail (Failure (Printf.sprintf "Invalid checksum. Expected %08lx got %08lx" expected_checksum checksum))
      else return () ) >>= fun () ->
    return { features; data_offset; time_stamp; creator_version; creator_application;
      creator_host_os; original_size; current_size; geometry; disk_type; checksum; uid; saved_state }

  let compute_checksum t =
    (* No alignment necessary *)
    let buf = Cstruct.of_bigarray (Bigarray.(Array1.create char c_layout sizeof)) in
    let t = marshal buf t in
    t.checksum
end

module Platform_code = struct
  type t =
    | None
    | Wi2r
    | Wi2k
    | W2ru
    | W2ku
    | Mac
    | MacX

  let wi2r = 0x57693272l
  let wi2k = 0x5769326Bl
  let w2ru = 0x57327275l
  let w2ku = 0x57326b75l
  let mac = 0x4d616320l
  let macx = 0x4d616358l

  let of_int32 =
    let open Vhd_result in function
    | 0l -> Ok None
    | x when x = wi2r -> Ok Wi2r
    | x when x = wi2k -> Ok Wi2k
    | x when x = w2ru -> Ok W2ru
    | x when x = w2ku -> Ok W2ku
    | x when x = mac -> Ok Mac
    | x when x = macx -> Ok MacX
    | x -> Error (Failure (Printf.sprintf "unknown platform_code: %lx" x))

  let to_int32 = function
    | None -> 0l
    | Wi2r -> wi2r
    | Wi2k -> wi2k
    | W2ru -> w2ru
    | W2ku -> w2ku
    | Mac -> mac
    | MacX -> macx

  let to_string = function
    | None -> "None"
    | Wi2r -> "Wi2r [deprecated]"
    | Wi2k -> "Wi2k [deprecated]"
    | W2ru -> "W2ru"
    | W2ku -> "W2ku"
    | Mac  -> "Mac "
    | MacX -> "MacX"
end

module Parent_locator = struct
  type t = {
    platform_code : Platform_code.t;

    (* WARNING WARNING - the following field is measured in *bytes* because Viridian VHDs 
       do this. This is a deviation from the spec. When reading in this field, we multiply
       by 512 if the value is less than 511 *)
    platform_data_space : int32;
    platform_data_space_original : int32; (* Original unaltered value *)

    platform_data_length : int32;
    platform_data_offset : int64;
    platform_data : Cstruct.t;
  }

  let equal a b =
    true
    && (a.platform_code = b.platform_code)
    && (a.platform_data_space = b.platform_data_space)
    && (a.platform_data_space_original = b.platform_data_space_original)
    && (a.platform_data_length = b.platform_data_length)
    && (a.platform_data_offset = b.platform_data_offset)
    && (cstruct_equal a.platform_data b.platform_data)

  let null = {
    platform_code=Platform_code.None;
    platform_data_space=0l;
    platform_data_space_original=0l;
    platform_data_length=0l;
    platform_data_offset=0L;
    platform_data=Cstruct.create 0;
  }

  let to_string t =
    Printf.sprintf "(%s %lx %lx, %ld, 0x%Lx, %s)" (Platform_code.to_string t.platform_code)
      t.platform_data_space t.platform_data_space_original
      t.platform_data_length t.platform_data_offset (Cstruct.to_string t.platform_data)

  let to_filename t = match t.platform_code with
    | Platform_code.MacX ->
      (* Interpret as a NULL-terminated string *)
      let rec find_string from =
        if Cstruct.len t.platform_data <= from
        then t.platform_data
        else
          if Cstruct.get_uint8 t.platform_data from = 0
          then Cstruct.sub t.platform_data 0 from
          else find_string (from + 1) in
      let path = Cstruct.to_string (find_string 0) in
      let expected_prefix = "file://./" in
      let expected_prefix' = String.length expected_prefix in
      let startswith prefix x =
        let prefix' = String.length prefix and x' = String.length x in
        prefix' <= x' && (String.sub x 0 prefix' = prefix) in
      if startswith expected_prefix path
      then Some (String.sub path expected_prefix' (String.length path - expected_prefix'))
      else None
    | _ -> None

  cstruct header {
    uint32_t platform_code;
    uint32_t platform_data_space;
    uint32_t platform_data_length;
    uint32_t reserved;
    uint64_t platform_data_offset
  } as big_endian

  let sizeof = sizeof_header

  let marshal (buf: Cstruct.t) t =
    set_header_platform_code buf (Platform_code.to_int32 t.platform_code);
    set_header_platform_data_space buf (Int32.shift_right_logical t.platform_data_space sector_shift);
    set_header_platform_data_length buf t.platform_data_length;
    set_header_reserved buf 0l;
    set_header_platform_data_offset buf t.platform_data_offset

  let unmarshal (buf: Cstruct.t) =
    let open Vhd_result in
    Platform_code.of_int32 (get_header_platform_code buf) >>= fun platform_code ->
    let platform_data_space_original = get_header_platform_data_space buf in
    (* The spec says this field should be stored in sectors. However some viridian vhds
       store the value in bytes. We assume that any value we read < 512l is actually in
       sectors (511l sectors is adequate space for a filename) and any value >= 511l is
       in bytes. We store the unaltered on-disk value in [platform_data_space_original]
       and the decoded value in *bytes* in [platform_data_space]. *)
    let platform_data_space =
      if platform_data_space_original < 512l
      then Int32.shift_left platform_data_space_original sector_shift
      else platform_data_space_original in
    let platform_data_length = get_header_platform_data_length buf in
    let platform_data_offset = get_header_platform_data_offset buf in
    return { platform_code; platform_data_space_original; platform_data_space;
      platform_data_length; platform_data_offset;
      platform_data = Cstruct.create 0 }

  let from_filename filename =
    (* Convenience function when creating simple vhds which have only
       one parent locator in the standard place (offset 1536 bytes) *)
    let uri = "file://./" ^ filename in
    let platform_data = Cstruct.create (String.length uri) in
    Cstruct.blit_from_string uri 0 platform_data 0 (String.length uri);
    let locator0 = {
      platform_code = Platform_code.MacX;
      platform_data_space = 512l;      (* bytes *)
      platform_data_space_original=1l; (* sector *)
      platform_data_length = Int32.of_int (String.length uri);
      platform_data_offset = 1536L;
      platform_data;
    } in
    [| locator0; null; null; null; null; null; null; null; |] 
end

module Header = struct

  type t = {
    (* cxsparse *)
    (* 0xFFFFFFFF *)
    table_offset : int64;
    (* 0x00010000l *)
    max_table_entries : int;
    block_size_sectors_shift : int;
    checksum : int32;
    parent_unique_id : Uuidm.t;
    parent_time_stamp : int32;
    parent_unicode_name : int array;
    parent_locators : Parent_locator.t array;
  }

  let default_block_size_sectors_shift = 12 (* 1 lsl 12 = 4096 sectors = 2 MiB *)

  let create ~table_offset ~current_size
    ?(block_size_sectors_shift = default_block_size_sectors_shift)
    ?(checksum = 0l)
    ?(parent_unique_id = blank_uuid)
    ?(parent_time_stamp = 0l)
    ?(parent_unicode_name = [| |])
    ?(parent_locators = Array.make 8 Parent_locator.null) () =
    let open Int64 in
    (* Round up the size to the next block *)
    let shift = block_size_sectors_shift + sector_shift in
    let current_size = ((current_size ++ (1L lsl shift -- 1L)) lsr shift) lsl shift in
    let max_table_entries = to_int (current_size lsr shift) in
    { table_offset; max_table_entries; block_size_sectors_shift;
      checksum; parent_unique_id; parent_time_stamp; parent_unicode_name;
      parent_locators }

  let to_string t =
    Printf.sprintf "{ table_offset = %Ld; max_table_entries = %d; block_size_sectors_shift = %d; checksum = %ld; parent_unique_id = %s; parent_time_stamp = %ld parent_unicode_name = %s; parent_locators = [| %s |]"
      t.table_offset t.max_table_entries t.block_size_sectors_shift t.checksum
      (Uuidm.to_string t.parent_unique_id) t.parent_time_stamp (UTF16.to_string t.parent_unicode_name)
      (String.concat "; " (List.map Parent_locator.to_string (Array.to_list t.parent_locators)))

  let equal a b =
    true
    && (a.table_offset = b.table_offset)
    && (a.max_table_entries = b.max_table_entries)
    && (a.block_size_sectors_shift = b.block_size_sectors_shift)
    && (a.checksum = b.checksum)
    && (a.parent_unique_id = b.parent_unique_id)
    && (a.parent_time_stamp = b.parent_time_stamp)
    && (a.parent_unicode_name = b.parent_unicode_name)
    && (Array.length a.parent_locators = (Array.length b.parent_locators))
    && (try
          for i = 0 to Array.length a.parent_locators - 1 do
            if not(Parent_locator.equal a.parent_locators.(i) b.parent_locators.(i))
            then raise Not_found (* arbitrary exn *)
          done;
          true
        with _ -> false)

  (* 1 bit per each 512 byte sector within the block *)
  let sizeof_bitmap t = 1 lsl (t.block_size_sectors_shift - 3)

  let magic = "cxsparse"

  let expected_data_offset = 0xFFFFFFFFFFFFFFFFL (* XXX: the spec says 8 bytes containing 0xFFFFFFFF *)

  let expected_version = 0x00010000l

  let default_block_size = 1 lsl (default_block_size_sectors_shift + sector_shift)

  let dump t =
    Printf.printf "VHD HEADER\n";
    Printf.printf "-=-=-=-=-=\n";
    Printf.printf "cookie              : %s\n" magic;
    Printf.printf "data_offset         : %Lx\n" expected_data_offset;
    Printf.printf "table_offset        : %Lu\n" t.table_offset;
    Printf.printf "header_version      : 0x%lx\n" expected_version;
    Printf.printf "max_table_entries   : 0x%x\n" t.max_table_entries;
    Printf.printf "block_size          : 0x%x\n" ((1 lsl t.block_size_sectors_shift) * sector_size);
    Printf.printf "checksum            : %lu\n" t.checksum;
    Printf.printf "parent_unique_id    : %s\n" (Uuidm.to_string t.parent_unique_id);
    Printf.printf "parent_time_stamp   : %lu\n" t.parent_time_stamp;
    let s = match UTF16.to_utf8 t.parent_unicode_name with
      | Vhd_result.Ok s -> s
      | Vhd_result.Error e -> Printf.sprintf "<Unable to decode UTF-16: %s>" (String.concat " " (List.map (fun x -> Printf.sprintf "%02x" x) (Array.to_list t.parent_unicode_name))) in
    Printf.printf "parent_unicode_name : '%s' (%d bytes)\n" s (Array.length t.parent_unicode_name);
    Printf.printf "parent_locators     : %s\n" 
      (String.concat "\n                      " (List.map Parent_locator.to_string (Array.to_list t.parent_locators)))

  cstruct header {
    uint8_t magic[8];
    uint64_t data_offset;
    uint64_t table_offset;
    uint32_t header_version;
    uint32_t max_table_entries;
    uint32_t block_size;
    uint32_t checksum;
    uint8_t parent_unique_id[16];
    uint32_t parent_time_stamp;
    uint32_t reserved;
    uint8_t parent_unicode_name[512]
    (* 8 parent locators *)
    (* 256 reserved *)
  } as big_endian

  let sizeof = sizeof_header + (8 * Parent_locator.sizeof) + 256

  let unicode_offset = 8 + 8 + 8 + 4 + 4 + 4 + 4 + 16 + 4 + 4

  let marshal (buf: Cstruct.t) t =
    set_header_magic magic 0 buf;
    set_header_data_offset buf expected_data_offset;
    set_header_table_offset buf t.table_offset;
    set_header_header_version buf expected_version;
    set_header_max_table_entries buf (Int32.of_int t.max_table_entries);
    set_header_block_size buf (Int32.of_int (1 lsl (t.block_size_sectors_shift + sector_shift)));
    set_header_checksum buf 0l;
    set_header_parent_unique_id (Uuidm.to_bytes t.parent_unique_id) 0 buf;
    set_header_parent_time_stamp buf t.parent_time_stamp;
    set_header_reserved buf 0l;
    for i = 0 to 511 do
      Cstruct.set_uint8 buf (unicode_offset + i) 0
    done;
    let (_: Cstruct.t) = UTF16.marshal (Cstruct.shift buf unicode_offset) t.parent_unicode_name in
    let parent_locators = Cstruct.shift buf (unicode_offset + 512) in
    for i = 0 to 7 do
      let buf = Cstruct.shift parent_locators (Parent_locator.sizeof * i) in
      let pl = if Array.length t.parent_locators <= i then Parent_locator.null else t.parent_locators.(i) in
      Parent_locator.marshal buf pl
    done;
    let reserved = Cstruct.shift parent_locators (8 * Parent_locator.sizeof) in
    for i = 0 to 255 do
      Cstruct.set_uint8 reserved i 0
    done;
    let checksum = Checksum.of_cstruct (Cstruct.sub buf 0 sizeof) in
    set_header_checksum buf checksum;
    { t with checksum }

  let unmarshal (buf: Cstruct.t) =
    let open Vhd_result in
    let magic' = copy_header_magic buf in
    ( if magic' <> magic
      then fail (Failure (Printf.sprintf "Expected cookie %s, got %s" magic magic'))
      else return () ) >>= fun () ->
    let data_offset = get_header_data_offset buf in
    ( if data_offset <> expected_data_offset
      then fail (Failure (Printf.sprintf "Expected header data_offset %Lx, got %Lx" expected_data_offset data_offset))
      else return () ) >>= fun () ->
    let table_offset = get_header_table_offset buf in
    let header_version = get_header_header_version buf in
    ( if header_version <> expected_version
      then fail (Failure (Printf.sprintf "Expected header_version %lx, got %lx" expected_version header_version))
      else return () ) >>= fun () ->
    let max_table_entries = get_header_max_table_entries buf in
    ( if Int64.of_int32 max_table_entries > Int64.of_int Sys.max_array_length
      then fail (Failure (Printf.sprintf "expected max_table_entries < %d, got %ld" Sys.max_array_length max_table_entries))
      else return (Int32.to_int max_table_entries) ) >>= fun max_table_entries ->
    let block_size = get_header_block_size buf in
    let rec to_shift acc = function
      | 0 -> fail (Failure "block size is zero")
      | 1 -> return acc
      | n when n mod 2 = 1 -> fail (Failure (Printf.sprintf "block_size is not a power of 2: %lx" block_size))
      | n -> to_shift (acc + 1) (n / 2) in
    to_shift 0 (Int32.to_int block_size) >>= fun block_size_shift ->
    let block_size_sectors_shift = block_size_shift - sector_shift in
    let checksum = get_header_checksum buf in
    let bytes = copy_header_parent_unique_id buf in
    ( match (Uuidm.of_bytes bytes) with
      | None -> fail (Failure (Printf.sprintf "Failed to decode UUID: %s" (String.escaped bytes)))
      | Some x -> return x ) >>= fun parent_unique_id ->
    let parent_time_stamp = get_header_parent_time_stamp buf in
    UTF16.unmarshal (Cstruct.sub buf unicode_offset 512) 512 >>= fun parent_unicode_name ->
    let parent_locators_buf = Cstruct.shift buf (unicode_offset + 512) in
    let parent_locators = Array.create 8 Parent_locator.null in
    let rec loop = function
      | 8 -> return ()
      | i ->
        let buf = Cstruct.shift parent_locators_buf (Parent_locator.sizeof * i) in
        Parent_locator.unmarshal buf >>= fun p ->
        parent_locators.(i) <- p;
        loop (i + 1) in
    loop 0 >>= fun () ->
    let expected_checksum = Checksum.(sub_int32 (of_cstruct (Cstruct.sub buf 0 sizeof)) checksum) in
    ( if checksum <> expected_checksum
      then fail (Failure (Printf.sprintf "Invalid checksum. Expected %08lx got %08lx" expected_checksum checksum))
      else return () ) >>= fun () ->
    return { table_offset; max_table_entries; block_size_sectors_shift; checksum; parent_unique_id;
      parent_time_stamp; parent_unicode_name; parent_locators }

  let compute_checksum t =
    (* No alignment necessary *)
    let buf = Cstruct.of_bigarray (Bigarray.(Array1.create char c_layout sizeof)) in
    let t = marshal buf t in
    t.checksum
end

module BAT = struct
  type t = {
    max_table_entries: int;
    data: Cstruct.t;
    mutable highest_value: int32;
  }

  let unused = 0xffffffffl

  let get t i = Cstruct.BE.get_uint32 t.data (i * 4)
  let set t i j =
    Cstruct.BE.set_uint32 t.data (i * 4) j;
    (* TODO: we need a proper free 'list' if we are going to allow blocks to be deallocated
       eg through TRIM *)
    if j <> unused && j > t.highest_value
    then t.highest_value <- j

  let length t = t.max_table_entries

  let equal t1 t2 =
    true
    && t1.highest_value = t2.highest_value
    && t1.max_table_entries = t2.max_table_entries
    && (try
         for i = 0 to length t1 - 1 do
           if get t1 i <> get t2 i then raise Not_found
         done;
         true
       with Not_found -> false)

  (* We always round up the size of the BAT to the next sector *)
  let sizeof_bytes (header: Header.t) =
    let size_needed = header.Header.max_table_entries * 4 in
    (* The BAT is always extended to a sector boundary *)
    roundup_sector size_needed

  let of_buffer (header: Header.t) (data: Cstruct.t) =
    for i = 0 to (Cstruct.len data) / 4 - 1 do
      Cstruct.BE.set_uint32 data (i * 4) unused
    done;
    { max_table_entries = header.Header.max_table_entries; data; highest_value = -1l; }

  let to_string (t: t) =
    let used = ref [] in
    for i = 0 to length t - 1 do
      if get t i <> unused then used := (i, get t i) :: !used
    done;
    Printf.sprintf "(%d rounded to %d)[ %s ] with highest_value = %ld" (length t) (Cstruct.len t.data / 4) (String.concat "; " (List.map (fun (i, x) -> Printf.sprintf "(%d, %lx)" i x) (List.rev !used))) t.highest_value

  let unmarshal (buf: Cstruct.t) (header: Header.t) =
    let t = {
      data = buf;
      max_table_entries = header.Header.max_table_entries;
      highest_value = -1l;
    } in
    for i = 0 to length t - 1 do
      if get t i > t.highest_value then t.highest_value <- get t i
    done;
    t

  let marshal (buf: Cstruct.t) (t: t) =
    Cstruct.blit t.data 0 buf 0 (Cstruct.len t.data)
  
  let dump t =
    Printf.printf "BAT\n";
    Printf.printf "-=-\n";
    for i = 0 to t.max_table_entries - 1 do
      Printf.printf "%d\t:0x%lx\n" i (get t i)
    done
end

module Batmap_header = struct

  cstruct header {
    uint8_t magic[8];
    uint64_t offset;
    uint32_t size_in_sectors;
    uint16_t major_version;
    uint16_t minor_version;
    uint32_t checksum;
    uint8_t marker
  } as big_endian

  let magic = "tdbatmap"

  let current_major_version = 1
  let current_minor_version = 2

  let sizeof = roundup_sector sizeof_header

  type t = {
    offset: int64;
    size_in_sectors: int;
    major_version: int;
    minor_version: int;
    checksum: int32;
    marker: int
  }

  let unmarshal (buf: Cstruct.t) =
    let open Vhd_result in
    let magic' = copy_header_magic buf in
    ( if magic' <> magic
      then fail (Failure (Printf.sprintf "Expected cookie %s, got %s" magic magic'))
      else return () ) >>= fun () ->
    let offset = get_header_offset buf in
    let size_in_sectors = Int32.to_int (get_header_size_in_sectors buf) in
    let major_version = get_header_major_version buf in
    let minor_version = get_header_minor_version buf in
    ( if major_version <> current_major_version || minor_version <> current_minor_version
      then fail (Failure (Printf.sprintf "Unexpected BATmap version: %d.%d" major_version minor_version))
      else return () ) >>= fun () ->
    let checksum = get_header_checksum buf in
    let marker = get_header_marker buf in
    return { offset; size_in_sectors; major_version; minor_version; checksum; marker }

  let marshal (buf: Cstruct.t) (t: t) =
    for i = 0 to Cstruct.len buf - 1 do
      Cstruct.set_uint8 buf i 0
    done;
    set_header_offset buf t.offset;
    set_header_size_in_sectors buf (Int32.of_int t.size_in_sectors);
    set_header_major_version buf t.major_version;
    set_header_minor_version buf t.minor_version;
    set_header_checksum buf t.checksum;
    set_header_marker buf t.marker

  let offset (x: Header.t) =
    Int64.(x.Header.table_offset ++ (of_int (BAT.sizeof_bytes x)))

end

module Batmap = struct
  type t = Cstruct.t

  let sizeof_bytes (x: Header.t) = (x.Header.max_table_entries + 7) lsr 3

  let sizeof (x: Header.t) = roundup_sector (sizeof_bytes x)

  let set t n =
    let byte = Cstruct.get_uint8 t (n / 8) in
    let bit = n mod 8 in
    let mask = 0x80 lsr bit in
    Cstruct.set_uint8 t (n / 8) (byte lor mask)

  let get t n =
    let byte = Cstruct.get_uint8 t (n / 8) in
    let bit = n mod 8 in
    let mask = 0x80 lsr bit in
    byte land mask <> mask

  let unmarshal (buf: Cstruct.t) (h: Header.t) (bh: Batmap_header.t) =
    let open Vhd_result in
    let needed = Cstruct.sub buf 0 (sizeof_bytes h) in
    let checksum = Checksum.of_cstruct buf in
    ( if checksum <> bh.Batmap_header.checksum
      then fail (Failure (Printf.sprintf "Invalid checksum. Expected %08lx got %08lx" bh.Batmap_header.checksum checksum))
      else return () ) >>= fun () ->
    return needed

end

module Bitmap = struct
  type t =
    | Full
    | Partial of Cstruct.t

  let get t sector_in_block = match t with
    | Full -> true
    | Partial buf ->
      let sector_in_block = Int64.to_int sector_in_block in
      let bitmap_byte = Cstruct.get_uint8 buf (sector_in_block / 8) in
      let bitmap_bit = sector_in_block mod 8 in
      let mask = 0x80 lsr bitmap_bit in
      (bitmap_byte land mask) = mask

  let set t sector_in_block = match t with
    | Full -> None (* already set, no on-disk update required *)
    | Partial buf ->
      let sector_in_block = Int64.to_int sector_in_block in
      let bitmap_byte = Cstruct.get_uint8 buf (sector_in_block / 8) in
      let bitmap_bit = sector_in_block mod 8 in
      let mask = 0x80 lsr bitmap_bit in
      if (bitmap_byte land mask) = mask
      then None (* already set, no on-disk update required *)
      else begin
        (* not set, we must update the sector on disk *)
        let byte_offset = sector_in_block / 8 in
        Cstruct.set_uint8 buf byte_offset (bitmap_byte lor mask);
        let sector_start = (byte_offset lsr sector_shift) lsl sector_shift in
        Some (Int64.of_int sector_start, Cstruct.sub buf sector_start sector_size)
      end
end

module Sector = struct
  type t = Cstruct.t

  let dump t =
    if Cstruct.len t = 0
    then Printf.printf "Empty sector\n"
    else
      for i=0 to Cstruct.len t - 1 do
        if (i mod 16 = 15) then
          Printf.printf "%02x\n" (Cstruct.get_uint8 t i)
        else
          Printf.printf "%02x " (Cstruct.get_uint8 t i)
      done

end

module Vhd = struct
  type 'a t = {
    filename: string;
    handle: 'a;
    header: Header.t;
    footer: Footer.t;
    parent: 'a t option;
    bat: BAT.t;
    batmap: (Batmap_header.t * Batmap.t) option;
    bitmap_cache: (int * Bitmap.t) option ref; (* effective only for streaming *)
  }

  let rec dump t =
    Printf.printf "VHD file: %s\n" t.filename;
    Header.dump t.header;
    Footer.dump t.footer;
    match t.parent with
    | None -> ()
    | Some parent -> dump parent

  let used_max_table_entries t =
    (* Some tools will create a larger-than-necessary BAT for small .vhds to
       allow the virtual size to be changed later. *)
    let max_table_entries = t.header.Header.max_table_entries in
    let block_size_bytes_shift = t.header.Header.block_size_sectors_shift + sector_shift in
    let current_size_blocks = Int64.(to_int (shift_right (add t.footer.Footer.current_size (sub (1L lsl block_size_bytes_shift) 1L)) block_size_bytes_shift)) in
    if current_size_blocks > max_table_entries
    then failwith (Printf.sprintf "max_table_entries (%d) < current size (%d) expressed in blocks (1 << %d)" max_table_entries current_size_blocks block_size_bytes_shift);
    current_size_blocks

  type block_marker = 
    | Start of (string * int64)
    | End of (string * int64)

  (* Nb this only copes with dynamic or differencing disks *)
  let check_overlapping_blocks t = 
    let tomarkers name start length =
      [Start (name,start); End (name,Int64.sub (Int64.add start length) 1L)] in
    let blocks = tomarkers "footer_at_top" 0L 512L in
    let blocks = (tomarkers "header" t.footer.Footer.data_offset 1024L) @ blocks in
    let blocks =
      if t.footer.Footer.disk_type = Disk_type.Differencing_hard_disk then begin
        let locators = Array.mapi (fun i l -> (i,l)) t.header.Header.parent_locators in
        let locators = Array.to_list locators in
        let open Parent_locator in
        let locators = List.filter (fun (_,l) -> l.platform_code <> Platform_code.None) locators in
        let locations = List.map (fun (i,l) -> 
          let name = Printf.sprintf "locator block %d" i in
          let start = l.platform_data_offset in
          let length = Int64.of_int32 l.platform_data_space in
          tomarkers name start length) locators in
        (List.flatten locations) @ blocks
      end else blocks in
    let bat_start = t.header.Header.table_offset in
    let bat_size = Int64.of_int t.header.Header.max_table_entries in
    let bat = tomarkers "BAT" bat_start bat_size in
    let blocks = bat @ blocks in
    let bat_blocks = ref [] in
    for i = 0 to BAT.length t.bat - 1 do
      let e = BAT.get t.bat i in
      if e <> BAT.unused then begin
        let name = Printf.sprintf "block %d" i in
        let start = Int64.mul 512L (Int64.of_int32 (BAT.get t.bat i)) in
        let size = Int64.shift_left 1L (t.header.Header.block_size_sectors_shift + sector_shift) in
        bat_blocks := (tomarkers name start size) @ !bat_blocks
      end
    done;
    let blocks = blocks @ !bat_blocks in
    let get_pos = function | Start (_,a) -> a | End (_,a) -> a in
    let to_string = function
    | Start (name,pos) -> Printf.sprintf "%Lx START of section '%s'" pos name
    | End (name,pos) -> Printf.sprintf "%Lx END of section '%s'" pos name in
    let l = List.sort (fun a b -> compare (get_pos a) (get_pos b)) blocks in
    List.iter (fun marker -> Printf.printf "%s\n" (to_string marker)) l

  exception EmptyVHD

  let get_top_unused_offset header bat =
    let open Int64 in
    try
      let last_block_start =
        let max_entry = bat.BAT.highest_value in
        if max_entry = -1l then raise EmptyVHD;
        512L ** (of_int32 max_entry) in
      last_block_start ++ (of_int (Header.sizeof_bitmap header)) ++ (1L lsl (header.Header.block_size_sectors_shift + sector_shift))
    with 
      | EmptyVHD ->
        let pos = add header.Header.table_offset 
          (mul 4L (of_int header.Header.max_table_entries)) in
        pos

  (* TODO: need a quicker block allocator *)
  let get_free_sector header bat =
    let open Int64 in
    let next_free_byte = get_top_unused_offset header bat in
    to_int32 ((next_free_byte ++ 511L) lsr sector_shift)

  module Field = struct
    (** Dynamically-typed field-level access *)

    type 'a f = {
      name: string;
      get: 'a t -> string;
    }

    let _features = "features"
    let _data_offset = "data-offset"
    let _timestamp = "time-stamp"
    let _creator_application = "creator-application"
    let _creator_version = "creator_version"
    let _creator_host_os = "creator-host-os"
    let _original_size = "original-size"
    let _current_size = "current-size"
    let _geometry = "geometry"
    let _disk_type = "disk-type"
    let _footer_checksum = "footer-checksum"
    let _uuid = "uuid"
    let _saved_state = "saved-state"
    let _table_offset = "table-offset"
    let _max_table_entries = "max-table-entries"
    let _block_size_sectors_shift = "block-size-sectors-shift"
    let _header_checksum = "header-checksum"
    let _parent_uuid = "parent_unique_id"
    let _parent_time_stamp = "parent-time-stamp"
    let _parent_unicode_name = "parent-unicode-name"
    let _parent_locator_prefix = "parent-locator-"
    let _parent_locator_prefix_len = String.length _parent_locator_prefix
    let _batmap_version = "batmap-version"
    let _batmap_offset = "batmap-offset"
    let _batmap_size_in_sectors = "batmap-size-in-sectors"
    let _batmap_checksum = "batmap-checksum"

    let list = [ _features; _data_offset; _timestamp; _creator_application;
      _creator_version; _creator_host_os; _original_size; _current_size;
      _geometry; _disk_type; _footer_checksum; _uuid; _saved_state;
      _table_offset; _max_table_entries; _block_size_sectors_shift;
      _header_checksum; _parent_uuid; _parent_time_stamp; _parent_unicode_name
    ] @ (List.map (fun x -> _parent_locator_prefix ^ (string_of_int x)) [0; 1; 2; 3; 4; 5; 6;7]
    ) @ [
      _batmap_version; _batmap_offset; _batmap_size_in_sectors; _batmap_checksum
    ]

    let startswith prefix x =
      let prefix' = String.length prefix and x' = String.length x in
      prefix' <= x' && (String.sub x 0 prefix' = prefix)

    let get t key =
      let opt f = function
        | None -> None
        | Some x -> Some (f x) in
      if key = _features
      then Some (String.concat ", " (List.map Feature.to_string t.footer.Footer.features))
      else if key = _data_offset
      then Some (Int64.to_string t.footer.Footer.data_offset)
      else if key = _timestamp
      then Some (Int32.to_string t.footer.Footer.time_stamp)
      else if key = _creator_application
      then Some t.footer.Footer.creator_application
      else if key = _creator_version
      then Some (Int32.to_string t.footer.Footer.creator_version)
      else if key = _creator_host_os
      then Some (Host_OS.to_string t.footer.Footer.creator_host_os)
      else if key = _original_size
      then Some (Int64.to_string t.footer.Footer.original_size)
      else if key = _current_size
      then Some (Int64.to_string t.footer.Footer.current_size)
      else if key = _geometry
      then Some (Geometry.to_string t.footer.Footer.geometry)
      else if key = _disk_type
      then Some (Disk_type.to_string t.footer.Footer.disk_type)
      else if key = _footer_checksum
      then Some (Int32.to_string t.footer.Footer.checksum)
      else if key = _uuid
      then Some (Uuidm.to_string t.footer.Footer.uid)
      else if key = _saved_state
      then Some (string_of_bool t.footer.Footer.saved_state)
      else if key = _table_offset
      then Some (Int64.to_string t.header.Header.table_offset)
      else if key = _max_table_entries
      then Some (string_of_int t.header.Header.max_table_entries)
      else if key = _block_size_sectors_shift
      then Some (string_of_int t.header.Header.block_size_sectors_shift)
      else if key = _header_checksum
      then Some (Int32.to_string t.header.Header.checksum)
      else if key = _parent_uuid
      then Some (Uuidm.to_string t.header.Header.parent_unique_id)
      else if key = _parent_time_stamp
      then Some (Int32.to_string t.header.Header.parent_time_stamp)
      else if key = _parent_unicode_name
      then Some (UTF16.to_utf8_exn t.header.Header.parent_unicode_name)
      else if startswith _parent_locator_prefix key then begin
        try
          let i = int_of_string (String.sub key _parent_locator_prefix_len (String.length key - _parent_locator_prefix_len)) in
          Some (Parent_locator.to_string t.header.Header.parent_locators.(i))
        with _ -> None
      end
      else if key = _batmap_version
      then opt (fun (t, _) -> Printf.sprintf "%d.%d" t.Batmap_header.major_version t.Batmap_header.minor_version) t.batmap
      else if key = _batmap_offset
      then opt (fun (t, _) -> Int64.to_string t.Batmap_header.offset) t.batmap
      else if key = _batmap_size_in_sectors
      then opt (fun (t, _) -> string_of_int t.Batmap_header.size_in_sectors) t.batmap
      else if key = _batmap_checksum
      then opt (fun (t, _) -> Int32.to_string t.Batmap_header.checksum) t.batmap
      else None
    type 'a t = 'a f

   end
end

module Raw = struct
  type 'a t = {
    filename: string;
    handle: 'a;
  }
end

type size = {
  total: int64;
  metadata: int64; (* TODO: rename to 'data' *)
  empty: int64;
  copy: int64;
}

let empty = { total = 0L; metadata = 0L; empty = 0L; copy = 0L }

module Stream = functor(A: S.ASYNC) -> struct
  open A

  type 'a ll =
    | Cons of 'a * (unit -> 'a ll t)
    | End

  let rec iter f = function
    | Cons(x, rest) ->
      f x >>= fun () ->
      rest () >>= fun x ->
      iter f x
    | End ->
      return ()

  let rec fold_left f initial xs = match xs with
    | End -> return initial
    | Cons (x, rest) ->
      f initial x >>= fun initial' ->
      rest () >>= fun xs ->
      fold_left f initial' xs

  type 'a stream = {
    elements: 'a Element.t ll;
    size: size;
  }

end

module Make = functor(File: S.IO) -> struct
  open File

  (* Convert Result.Error values into failed threads *)
  let (>>|=) m f = match m with
    | Vhd_result.Error e -> fail e
    | Vhd_result.Ok x -> f x

  (* Search a path for a filename *)
  let search filename path =
    let rec loop = function
    | [] -> return None
    | x :: xs ->
      let possibility = Filename.concat x filename in
      ( File.exists possibility >>= function
        | true -> return (Some possibility)
        | false -> loop xs ) in
    if Filename.is_relative filename
    then loop path
    else loop [ "" ]

  let rec unaligned_really_write fd offset buffer =
    let open Int64 in
    let sector_start = (offset lsr sector_shift) lsl sector_shift in
    really_read fd sector_start sector_size >>= fun current ->
    let adjusted_len = offset ++ (of_int (Cstruct.len buffer)) -- sector_start in
    let write_this_time = max adjusted_len 512L in
    let remaining_to_write = adjusted_len -- write_this_time in

    let useful_bytes_to_write = min (Cstruct.len buffer) (to_int (write_this_time -- offset ++ sector_start)) in
    Cstruct.blit buffer 0 current (to_int (offset -- sector_start)) useful_bytes_to_write;
    really_write fd sector_start current >>= fun () ->
    if remaining_to_write <= 0L
    then return ()
    else unaligned_really_write fd (offset ++ (of_int useful_bytes_to_write)) (Cstruct.shift buffer useful_bytes_to_write)

  module Footer_IO = struct
    open Footer

    let read fd pos =
      really_read fd pos Footer.sizeof >>= fun buf ->
      Footer.unmarshal buf >>|= fun x ->
      return x

    let write sector fd pos t =
      let t = Footer.marshal sector t in
      really_write fd pos sector >>= fun () ->
      return t
  end

  module Parent_locator_IO = struct
    open Parent_locator

    let read fd t =
      let l = Int32.to_int t.platform_data_length in
      let l_rounded = roundup_sector l in
      ( if l_rounded = 0
        then return (Cstruct.create 0)
        else really_read fd t.platform_data_offset l_rounded ) >>= fun platform_data ->
      let platform_data = Cstruct.sub platform_data 0 l in
      return { t with platform_data }

    let write fd t =
      (* Only write those that actually have a platform_code *)
      if t.platform_code <> Platform_code.None
      then unaligned_really_write fd t.platform_data_offset t.platform_data
      else return ()
  end

  module Header_IO = struct
    open Header

    let get_parent_filename t search_path =
      let rec test n =
        if n >= Array.length t.parent_locators
        then fail (Failure "Failed to find parent!")
        else
          let l = t.parent_locators.(n) in
          let open Parent_locator in
          match to_filename l with
          | Some path ->
            ( search path search_path >>= function
              | None -> test (n + 1)
              | Some path -> return path )
          | None -> test (n + 1) in
      test 0

    let read fd pos =
      really_read fd pos sizeof >>= fun buf ->
      unmarshal buf >>|= fun t -> 
      (* Read the parent_locator data *)
      let rec read_parent_locator = function
        | 8 -> return ()
        | n ->
          let p = t.parent_locators.(n) in
          let open Parent_locator in
          Parent_locator_IO.read fd p >>= fun p ->
          t.parent_locators.(n) <- p;
          read_parent_locator (n + 1) in
      read_parent_locator 0 >>= fun () ->
      return t  

    let write buf fd pos t =
      let t' = marshal buf t in
      (* Write the parent_locator data *)
      let rec write_parent_locator = function
        | 8 -> return ()
        | n ->
          let p = t.parent_locators.(n) in
          let open Parent_locator in
          Parent_locator_IO.write fd p >>= fun () ->
          write_parent_locator (n + 1) in
      really_write fd pos buf >>= fun () ->
      write_parent_locator 0 >>= fun () ->
      return t'
  end

  module BAT_IO = struct
    open BAT

    let read fd (header: Header.t) =
      really_read fd header.Header.table_offset (sizeof_bytes header) >>= fun buf ->
      return (unmarshal buf header)

    let write buf fd (header: Header.t) t =
      marshal buf t;
      really_write fd header.Header.table_offset buf
  end

  module Batmap_IO = struct
    open Batmap

    let read fd (header: Header.t) =
      really_read fd (Batmap_header.offset header) Batmap_header.sizeof >>= fun buf ->
      match Batmap_header.unmarshal buf with
      | Vhd_result.Error _ -> return None
      | Vhd_result.Ok h ->
        ( really_read fd h.Batmap_header.offset (h.Batmap_header.size_in_sectors * sector_size) >>= fun batmap ->
          match Batmap.unmarshal batmap header h with
          | Vhd_result.Error _ -> return None
          | Vhd_result.Ok batmap ->
            return (Some (h, batmap)))
  end

  module Bitmap_IO = struct
    open Bitmap

    let read fd (header: Header.t) (bat: BAT.t) (block: int) =
      let open Int64 in
      let pos = (of_int32 (BAT.get bat block)) lsl sector_shift in
      really_read fd pos (Header.sizeof_bitmap header) >>= fun bitmap ->
      return (Partial bitmap)
  end

  module Vhd_IO = struct
    open Vhd

    let write_trailing_footer buf handle t =
      let sector = Vhd.get_free_sector t.Vhd.header t.Vhd.bat in
      let offset = Int64.(shift_left (of_int32 sector) sector_shift) in
      Footer_IO.write buf handle offset t.Vhd.footer >>= fun _ ->
      return ()
    
    let write t =
      let footer_buf = File.alloc Footer.sizeof in
      Footer_IO.write footer_buf t.Vhd.handle 0L t.Vhd.footer >>= fun footer ->
      (* This causes the file size to be increased so we can successfully
         read empty blocks in places like the parent locators *)
      write_trailing_footer footer_buf t.Vhd.handle t >>= fun () ->
      let t ={ t with Vhd.footer } in
      let buf = File.alloc Header.sizeof in
      Header_IO.write buf t.Vhd.handle t.Vhd.footer.Footer.data_offset t.Vhd.header >>= fun header ->
      let t = { t with Vhd.header } in
      let buf = File.alloc (BAT.sizeof_bytes header) in
      BAT_IO.write buf t.Vhd.handle t.Vhd.header t.Vhd.bat >>= fun () ->
      (* Assume the data is there, or will be written later *)
      return t

    let create_dynamic ~filename ~size
      ?(uuid = Uuidm.create `V4)
      ?(saved_state=false)
      ?(features=[]) () =

      (* The physical disk layout will be:
         byte 0   - 511:  backup footer
         byte 512 - 1535: file header
         ... empty sector-- this is where we'll put the parent locator
         byte 2048 - ...: BAT *)

      let data_offset = 512L in
      let table_offset = 2048L in

      let open Int64 in

      let header = Header.create ~table_offset ~current_size:size () in
      let size = (of_int header.Header.max_table_entries) lsl (header.Header.block_size_sectors_shift + sector_shift) in
      let footer = Footer.create ~features ~data_offset ~current_size:size ~disk_type:Disk_type.Dynamic_hard_disk ~uid:uuid ~saved_state () in

      let bat_buffer = File.alloc (BAT.sizeof_bytes header) in
      let bat = BAT.of_buffer header bat_buffer in
      let batmap = None in
      File.create filename >>= fun handle ->
      let t = { filename; handle; header; footer; parent = None; bat; batmap; bitmap_cache = ref None } in
      write t >>= fun t ->
      return t

    let create_difference ~filename ~parent
      ?(uuid=Uuidm.create `V4)
      ?(saved_state=false)
      ?(features=[]) () =

      (* We use the same basic file layout as in create_dynamic *)

      let data_offset = 512L in
      let table_offset = 2048L in
      let footer = Footer.create ~features ~data_offset ~time_stamp:(File.now ())
        ~current_size:parent.Vhd.footer.Footer.current_size
        ~disk_type:Disk_type.Differencing_hard_disk
        ~uid:uuid ~saved_state () in
      let parent_locators = Parent_locator.from_filename parent.Vhd.filename in
      File.get_modification_time parent.Vhd.filename >>= fun parent_time_stamp ->
      let header = Header.create ~table_offset
        ~current_size:parent.Vhd.footer.Footer.current_size
        ~block_size_sectors_shift:parent.Vhd.header.Header.block_size_sectors_shift
        ~parent_unique_id:parent.Vhd.footer.Footer.uid
        ~parent_time_stamp
        ~parent_unicode_name:(UTF16.of_utf8 parent.Vhd.filename)
        ~parent_locators () in
      let bat_buffer = File.alloc (BAT.sizeof_bytes header) in
      let bat = BAT.of_buffer header bat_buffer in
      File.create filename >>= fun handle ->
      (* Re-open the parent file to avoid sharing the underlying file descriptor and
         having to perform reference counting *)
      File.openfile parent.Vhd.filename >>= fun parent_handle ->
      let parent = { parent with handle = parent_handle } in
      let batmap = None in
      let t = { filename; handle; header; footer; parent = Some parent; bat; batmap; bitmap_cache = ref None } in
      write t >>= fun t ->
      return t

    let rec openfile ?(path = ["."]) filename =
      search filename path >>= function
      | None -> fail (Failure (Printf.sprintf "Failed to find %s (search path = %s)" filename (String.concat ":" path)))
      | Some filename ->
        File.openfile filename >>= fun handle ->
        Footer_IO.read handle 0L >>= fun footer ->
        Header_IO.read handle (Int64.of_int Footer.sizeof) >>= fun header ->
        BAT_IO.read handle header >>= fun bat ->
        (match footer.Footer.disk_type with
          | Disk_type.Differencing_hard_disk ->
            Header_IO.get_parent_filename header path >>= fun parent_filename ->
            openfile ~path parent_filename >>= fun p ->
            return (Some p)
          | _ ->
            return None) >>= fun parent ->
        Batmap_IO.read handle header >>= fun batmap ->
        return { filename; handle; header; footer; bat; bitmap_cache = ref None; batmap; parent }

    let rec close t =
      (* This is where we could repair the footer if we have chosen not to
         update it for speed. *)
      File.close t.Vhd.handle >>= fun () ->
      match t.Vhd.parent with
      | None -> return ()
      | Some p -> close p

    (* Converts a virtual sector offset into a physical sector offset *)
    let rec get_sector_location t sector =
      let open Int64 in
      if sector lsl sector_shift > t.Vhd.footer.Footer.current_size
      then return None (* perhaps elements in the vhd chain have different sizes *)
      else
        let maybe_get_from_parent () = match t.Vhd.footer.Footer.disk_type,t.Vhd.parent with
          | Disk_type.Differencing_hard_disk,Some vhd2 -> get_sector_location vhd2 sector
          | Disk_type.Differencing_hard_disk,None -> fail (Failure "Sector in parent but no parent found!")
          | Disk_type.Dynamic_hard_disk,_ -> return None
          | Disk_type.Fixed_hard_disk,_ -> fail (Failure "Fixed disks are not supported") in

        let block_num = to_int (sector lsr t.Vhd.header.Header.block_size_sectors_shift) in
        let sector_in_block = rem sector (1L lsl t.Vhd.header.Header.block_size_sectors_shift) in
 
        if BAT.get t.Vhd.bat block_num = BAT.unused
        then maybe_get_from_parent ()
        else begin
          ( match !(t.Vhd.bitmap_cache) with
            | Some (block_num', bitmap) when block_num' = block_num -> return bitmap
            | _ ->
              Bitmap_IO.read t.Vhd.handle t.Vhd.header t.Vhd.bat block_num >>= fun bitmap ->
              t.Vhd.bitmap_cache := Some(block_num, bitmap);
              return bitmap ) >>= fun bitmap ->
          let in_this_bitmap = Bitmap.get bitmap sector_in_block in
          match t.Vhd.footer.Footer.disk_type, in_this_bitmap with
          | _, true ->
            let data_sector = (of_int32 (BAT.get t.Vhd.bat block_num)) ++ (of_int (Header.sizeof_bitmap t.Vhd.header) lsr sector_shift) ++ sector_in_block in
            return (Some(t, data_sector))
          | Disk_type.Dynamic_hard_disk, false ->
            return None
          | Disk_type.Differencing_hard_disk, false ->
            maybe_get_from_parent ()
          | Disk_type.Fixed_hard_disk, _ -> fail (Failure "Fixed disks are not supported")
        end  

    let read_sector t sector =
      let open Int64 in
      if sector < 0L || (sector lsl sector_shift >= t.Vhd.footer.Footer.current_size)
      then fail (Invalid_sector(sector, t.Vhd.footer.Footer.current_size lsr sector_shift))
      else get_sector_location t sector >>= function
      | None -> return None
      | Some (t, offset) ->
        really_read t.Vhd.handle (offset lsl sector_shift) sector_size >>= fun data ->
        return (Some data)

    let constant size v =
      let buf = File.alloc size in
      for i = 0 to size - 1 do
        Cstruct.set_uint8 buf i v
      done;
      buf

    let sectors_in_2mib = 2 * 1024 * 2
    let empty_2mib = constant (sectors_in_2mib * 512) 0

    let all_zeroes = constant 512 0
    let all_ones   = constant 512 0xff
 
    let write_zero_block handle t block_num =
      let block_size_in_sectors = 1 lsl t.Vhd.header.Header.block_size_sectors_shift in
      let open Int64 in
      let bitmap_size = Header.sizeof_bitmap t.Vhd.header in
      let bitmap_sector = of_int32 (BAT.get t.Vhd.bat block_num) in

      ( if bitmap_size = 512
        then really_write handle (bitmap_sector lsl sector_shift) all_zeroes
        else begin
          let bitmap = File.alloc bitmap_size in
          for i = 0 to bitmap_size - 1 do
            Cstruct.set_uint8 bitmap i 0
          done;
          really_write handle (bitmap_sector lsl sector_shift) bitmap
        end )
      >>= fun () ->

      let rec loop n =
        let pos = (bitmap_sector lsl sector_shift) ++ (of_int bitmap_size) ++ (of_int (sector_size * n)) in
        if n + sectors_in_2mib <= block_size_in_sectors
        then
          really_write handle pos empty_2mib >>= fun () ->
          loop (n + sectors_in_2mib)
        else
          if n >= block_size_in_sectors
          then return ()
          else
            really_write handle pos all_zeroes >>= fun () ->
            loop (n + 1) in
      loop 0

    let write_sector t sector data =
      let block_size_in_sectors = 1 lsl t.Vhd.header.Header.block_size_sectors_shift in
      let open Int64 in
      if sector < 0L || (sector lsl sector_shift >= t.Vhd.footer.Footer.current_size)
      then fail (Invalid_sector(sector, t.Vhd.footer.Footer.current_size lsr sector_shift))
      else
        let block_num = to_int (sector lsr t.Vhd.header.Header.block_size_sectors_shift) in
        assert (block_num < (BAT.length t.Vhd.bat));
        let sector_in_block = rem sector (of_int block_size_in_sectors) in
        let update_sector bitmap_sector =
          let bitmap_sector = of_int32 bitmap_sector in
          let data_sector = bitmap_sector ++ (of_int (Header.sizeof_bitmap t.Vhd.header) lsr sector_shift) ++ sector_in_block in
          Bitmap_IO.read t.Vhd.handle t.Vhd.header t.Vhd.bat block_num >>= fun bitmap ->
          really_write t.Vhd.handle (data_sector lsl sector_shift) data >>= fun () ->
          match Bitmap.set bitmap sector_in_block with
          | None -> return ()
          | Some (offset, buf) -> really_write t.Vhd.handle ((bitmap_sector lsl sector_shift) ++ offset) buf in

        if BAT.get t.Vhd.bat block_num = BAT.unused then begin
          BAT.set t.Vhd.bat block_num (Vhd.get_free_sector t.Vhd.header t.Vhd.bat);
          write_zero_block t.Vhd.handle t block_num >>= fun () ->
          let bat_buffer = File.alloc (BAT.sizeof_bytes t.Vhd.header) in
          BAT_IO.write bat_buffer t.Vhd.handle t.Vhd.header t.Vhd.bat >>= fun () ->
          let footer_buffer = File.alloc Footer.sizeof in
          write_trailing_footer footer_buffer t.Vhd.handle t >>= fun () ->
          update_sector (BAT.get t.Vhd.bat block_num)
        end else begin
          update_sector (BAT.get t.Vhd.bat block_num)
        end
  end

  module Raw_IO = struct
    open Raw

    let openfile filename =
      File.openfile filename >>= fun handle ->
      return { filename; handle }

    let close t =
      File.close t.handle

    let create ~filename ~size () =
      File.create filename >>= fun handle ->
      File.really_write handle size (Cstruct.create 0) >>= fun () ->
      return { filename; handle }
  end

  include Stream(File)
  open Element

  (* Test whether a block is in any BAT in the path to the root. If so then we will
     look up all sectors. *)
  let rec in_any_bat vhd i = match BAT.get vhd.Vhd.bat i <> BAT.unused, vhd.Vhd.parent with
    | true, _ -> true
    | false, Some parent -> in_any_bat parent i
    | false, None -> false

  let rec coalesce_request acc s =
    let open Int64 in
    s >>= fun next -> match next, acc with
    | End, None -> return End
    | End, Some x -> return (Cons(x, fun () -> return End))
    | Cons(Sectors s, next), None -> return(Cons(Sectors s, fun () -> coalesce_request None (next ())))
    | Cons(Sectors _, next), Some x -> return(Cons(x, fun () -> coalesce_request None s))
    | Cons(Empty n, next), None -> coalesce_request (Some(Empty n)) (next ())
    | Cons(Empty n, next), Some(Empty m) -> coalesce_request (Some(Empty (n ++ m))) (next ())
    | Cons(Empty n, next), Some x -> return (Cons(x, fun () -> coalesce_request None s))
    | Cons(Copy(h, ofs, len), next), None -> coalesce_request (Some (Copy(h, ofs, len))) (next ())
    | Cons(Copy(h, ofs, len), next), Some(Copy(h', ofs', len')) ->
      if ofs ++ len = ofs' && h == h'
      then coalesce_request (Some(Copy(h, ofs, len ++ len'))) (next ())
      else if ofs' ++ len' = ofs && h == h'
      then coalesce_request (Some(Copy(h, ofs', len ++ len'))) (next ())
      else return (Cons(Copy(h', ofs', len'), fun () -> coalesce_request None s))
    | Cons(Copy(h, ofs, len), next), Some x -> return(Cons(x, fun () -> coalesce_request None s))

  let twomib_bytes = 2 * 1024 * 1024
  let twomib_sectors = twomib_bytes / 512

  let rec expand_empty_elements twomib_empty s =
    let open Int64 in
    s >>= function
    | End -> return End
    | Cons(Empty n, next) ->
        let rec copy n =
          let this = to_int (min n (of_int twomib_sectors)) in
          let block = Cstruct.sub twomib_empty 0 (this * 512) in
          let n = n -- (of_int this) in
          let next () = if n > 0L then copy n else expand_empty_elements twomib_empty (next ()) in
          return (Cons(Sectors block, next)) in
        copy n
    | Cons(x, next) -> return (Cons(x, fun () -> expand_empty_elements twomib_empty (next ())))

  let expand_empty s =
    let open Int64 in
    let size = { s.size with empty = 0L; metadata = s.size.metadata ++ s.size.empty } in
    let twomib_empty =
      let b = Cstruct.create twomib_bytes in
      for i = 0 to twomib_bytes - 1 do
        Cstruct.set_uint8 b i 0
      done;
      b in
    expand_empty_elements twomib_empty (return s.elements) >>= fun elements ->
    return { elements; size }

  let rec expand_copy_elements buffer s =
    let open Int64 in
    s >>= function
    | End -> return End
    | Cons(Element.Copy(h, sector_start, sector_len), next) ->
        let rec copy sector_start sector_len =
          let this = to_int (min sector_len (of_int twomib_sectors)) in
          let data = Cstruct.sub buffer 0 (this * 512) in
          really_read_into h (sector_start ** 512L) data >>= fun data ->
          let sector_start = sector_start ++ (of_int this) in
          let sector_len = sector_len -- (of_int this) in
          let next () = if sector_len > 0L then copy sector_start sector_len else expand_copy_elements buffer (next ()) in
          return (Cons(Sectors data, next)) in
        copy sector_start sector_len
    | Cons(x, next) -> return (Cons(x, fun () -> expand_copy_elements buffer (next ())))

  let expand_copy s =
    let open Int64 in
    let size = { s.size with copy = 0L; metadata = s.size.metadata ++ s.size.copy } in
    let buffer = alloc twomib_bytes in
    expand_copy_elements buffer (return s.elements) >>= fun elements ->
    return { elements; size }

  module Vhd_input = struct

    (* If we're streaming a fully consolidated disk (where from = None) then we include
       blocks if they're in any BAT on the path to the tree root. If from = Some from
       then we must take the two paths to the tree root:
          t, from : vhd list
       and include blocks where
          x | x \in (from - t)    "we must revert changes specific to the 'from' branch"
       and
          x | x \in (t - from)    "we must include changes specific to the 't' branch"
    *)
    let include_block from t = match from with
      | None -> in_any_bat t
      | Some from ->
        let module BATS = Set.Make(struct type t = (string * BAT.t) let compare x y = compare (fst x) (fst y) end) in
        let rec make t =
          let rest = match t.Vhd.parent with
            | None -> BATS.empty
            | Some x -> make x in
          BATS.add (t.Vhd.filename, t.Vhd.bat) rest in
        let t_branch = make t in
        let from_branch = make from in
        let to_include = BATS.(union (diff t_branch from_branch) (diff from_branch t_branch)) in
        fun i ->
          BATS.fold (fun (_, bat) acc -> acc || (BAT.get bat i <> BAT.unused)) to_include false

  let hybrid ?from (raw: 'a) (vhd: fd Vhd.t) =
    let block_size_sectors_shift = vhd.Vhd.header.Header.block_size_sectors_shift in
    let block_size_sectors = Int64.shift_left 1L block_size_sectors_shift in
    let max_table_entries = Vhd.used_max_table_entries vhd in
    let empty_block = Empty block_size_sectors in

    let include_block = include_block from vhd in

    let rec block i =
      let next_block () = block (i + 1) in
      if i = max_table_entries
      then return End
      else begin
        if not(include_block i)
        then return (Cons(empty_block, next_block))
        else return (Cons(Copy(raw, Int64.(mul (of_int i) block_size_sectors), block_size_sectors), next_block))
      end in
    (* Note we avoid inspecting the sector bitmaps to avoid unnecessary seeking *)
    let block_size_bytes = Int64.shift_left block_size_sectors sector_shift in
    let rec count totals i =
      if i = max_table_entries
      then totals
      else begin
        if not(include_block i)
        then count { totals with empty = Int64.(add totals.empty block_size_bytes) } (i + 1)
        else count { totals with copy  = Int64.(add totals.copy  block_size_bytes) } (i + 1)
      end in
    coalesce_request None (block 0) >>= fun elements ->
    let size = count { empty with total = vhd.Vhd.footer.Footer.current_size } 0 in
    return { elements; size } 

  let raw ?from (vhd: fd Vhd.t) =
    let block_size_sectors_shift = vhd.Vhd.header.Header.block_size_sectors_shift in
    let max_table_entries = Vhd.used_max_table_entries vhd in
    let empty_block = Empty (Int64.shift_left 1L block_size_sectors_shift) in
    let empty_sector = Empty 1L in

    let include_block = include_block from vhd in

    let rec block i =
      let next_block () = block (i + 1) in
      if i = max_table_entries
      then return End
      else begin
        if not(include_block i)
        then return (Cons(empty_block, next_block))
        else begin
          let absolute_block_start = Int64.(shift_left (of_int i) block_size_sectors_shift) in
          let rec sector j =
            let next_sector () = sector (j + 1) in
            if j = 1 lsl block_size_sectors_shift
            then next_block ()
            else begin
              let absolute_sector = Int64.(add absolute_block_start (of_int j)) in
              Vhd_IO.get_sector_location vhd absolute_sector >>= function
              | None ->
                return (Cons(empty_sector, next_sector))
              | Some (vhd', offset) ->
                return (Cons(Copy(vhd'.Vhd.handle, offset, 1L), next_sector))
            end in
          sector 0
        end
      end in
    (* Note we avoid inspecting the sector bitmaps to avoid unnecessary seeking *)
    let rec count totals i =
      if i = max_table_entries
      then totals
      else begin
        if not(include_block i)
        then count { totals with empty = Int64.(add totals.empty (shift_left 1L (block_size_sectors_shift + sector_shift))) } (i + 1)
        else count { totals with copy  = Int64.(add totals.copy  (shift_left 1L (block_size_sectors_shift + sector_shift))) } (i + 1)
      end in
    coalesce_request None (block 0) >>= fun elements ->
    let size = count { empty with total = vhd.Vhd.footer.Footer.current_size } 0 in
    return { elements; size } 

  let vhd ?from ?(emit_batmap=false)(t: fd Vhd.t) =
    let block_size_sectors_shift = t.Vhd.header.Header.block_size_sectors_shift in
    let max_table_entries = Vhd.used_max_table_entries t in

    (* The physical disk layout will be:
       byte 0   - 511:  backup footer
       byte 512 - 1535: file header
       ... empty sector-- this is where we'll put the parent locator
       byte 2048 - ...: BAT
       Batmap_header | iff batmap
       Batmap        |
    *)

    let data_offset = 512L in
    let table_offset = 2048L in

    let size = t.Vhd.footer.Footer.current_size in
    let disk_type = match from with
      | None -> Disk_type.Dynamic_hard_disk
      | Some _ -> Disk_type.Differencing_hard_disk in
    let footer = Footer.create ~data_offset ~current_size:size ~disk_type () in
    ( match from with
      | None -> return (Header.create ~table_offset ~current_size:size ~block_size_sectors_shift ())
      | Some from ->
        let parent_locators = Parent_locator.from_filename from.Vhd.filename in
        File.get_modification_time from.Vhd.filename >>= fun parent_time_stamp ->
        let h = Header.create ~table_offset ~current_size:size ~block_size_sectors_shift
          ~parent_unique_id:from.Vhd.footer.Footer.uid
          ~parent_time_stamp
          ~parent_unicode_name:(UTF16.of_utf8 from.Vhd.filename)
          ~parent_locators () in
        return h ) >>= fun header ->

    let bat_buffer = File.alloc (BAT.sizeof_bytes header) in
    let bat = BAT.of_buffer header bat_buffer in

    let sizeof_bat = BAT.sizeof_bytes header in

    let sizeof_bitmap = Header.sizeof_bitmap header in
    (* We'll always set all bitmap bits *)
    let bitmap = File.alloc sizeof_bitmap in
    for i = 0 to sizeof_bitmap - 1 do
      Cstruct.set_uint8 bitmap i 0xff
    done;
    let sizeof_data_sectors = 1 lsl block_size_sectors_shift in
    let sizeof_data = 1 lsl (block_size_sectors_shift + sector_shift) in

    let include_block = include_block from t in

    (* Calculate where the first data block can go. Note the sizeof_bat is already
       rounded up to the next sector boundary. *)
    let next_free_sector_in_bytes = Int64.(table_offset ++ (of_int sizeof_bat)) in

    let batmap_header = File.alloc Batmap_header.sizeof in
    let batmap = File.alloc (Batmap.sizeof header) in
    for i = 0 to Batmap.sizeof header - 1 do
      Cstruct.set_uint8 batmap i 0
    done;

    let first_block =
      if emit_batmap
      then Int64.(next_free_sector_in_bytes ++ (of_int Batmap_header.sizeof) ++ (of_int (Batmap.sizeof header)))
      else next_free_sector_in_bytes in

    let next_byte = ref first_block in
    for i = 0 to max_table_entries - 1 do
      if include_block i then begin
        BAT.set bat i (Int64.(to_int32(!next_byte lsr sector_shift)));
        Batmap.set batmap i;
        next_byte := Int64.(!next_byte ++ (of_int sizeof_bitmap) ++ (of_int sizeof_data))
      end
    done;

    Batmap_header.marshal batmap_header {
      Batmap_header.offset = Int64.(next_free_sector_in_bytes ++ 512L);
      size_in_sectors = Batmap.sizeof header lsr sector_shift; 
      major_version = Batmap_header.current_major_version;
      minor_version = Batmap_header.current_minor_version;
      checksum = Checksum.of_cstruct batmap;
      marker = 0;
    };
    let rec write_sectors buf andthen =
      return(Cons(Sectors buf, andthen)) in

    let rec block i andthen =
      let rec sector j =
        let next () = if j = sizeof_data_sectors - 1 then block (i + 1) andthen else sector (j + 1) in
        let absolute_sector = Int64.(add (shift_left (of_int i) block_size_sectors_shift) (of_int j)) in
        Vhd_IO.get_sector_location t absolute_sector >>= function
        | None ->
          return (Cons(Empty 1L, next))
        | Some (vhd', offset) ->
          return (Cons(Copy(vhd'.Vhd.handle, offset, 1L), next)) in
      if i >= max_table_entries
      then andthen ()
      else
        if include_block i
        then return(Cons(Sectors bitmap, fun () -> sector 0))
        else block (i + 1) andthen in

    let batmap andthen =
      if emit_batmap 
      then write_sectors batmap_header (fun () -> write_sectors batmap andthen)
      else andthen () in

    assert(Footer.sizeof = 512);
    assert(Header.sizeof = 1024);

    let buf = File.alloc (max Footer.sizeof (max Header.sizeof sizeof_bat)) in
    let (_: Footer.t) = Footer.marshal buf footer in
    coalesce_request None (return (Cons(Sectors(Cstruct.sub buf 0 Footer.sizeof), fun () ->
      let (_: Header.t) = Header.marshal buf header in
      write_sectors (Cstruct.sub buf 0 Header.sizeof) (fun () ->
        return(Cons(Empty 1L, fun () ->
          BAT.marshal buf bat;
          write_sectors (Cstruct.sub buf 0 sizeof_bat) (fun () ->
            let (_: Footer.t) = Footer.marshal buf footer in
            batmap (fun () ->
              block 0 (fun () ->
                return(Cons(Sectors(Cstruct.sub buf 0 Footer.sizeof), fun () -> return End))
              )
            )
          )
       ))
     )
    ))) >>= fun elements ->

    (* Note we avoid inspecting the sector bitmaps to avoid unnecessary seeking *)
    let rec count totals i =
      if i = max_table_entries
      then totals
      else begin
        if not(include_block i)
        then count { totals with empty = Int64.(add totals.empty (shift_left 1L (block_size_sectors_shift + sector_shift))) } (i + 1)
        else count { totals with copy  = Int64.(add totals.copy  (shift_left 1L (block_size_sectors_shift + sector_shift)));
                                 metadata = Int64.(add totals.metadata (of_int sizeof_bitmap))  } (i + 1)
      end in
    let size = { empty with metadata = Int64.of_int ((2 * Footer.sizeof + Header.sizeof + sizeof_bat) / 512);
                            empty = 512L;
                            total = t.Vhd.footer.Footer.current_size } in
    let size = count size 0 in
    return { elements; size } 

    end

   module Raw_input = struct
     open Raw

     let vhd t =
       (* The physical disk layout will be:
          byte 0   - 511:  backup footer
          byte 512 - 1535: file header
          ... empty sector-- this is where we'll put the parent locator
          byte 2048 - ...: BAT *)

       let data_offset = 512L in
       let table_offset = 2048L in

       File.get_file_size t.filename >>= fun current_size ->
       let header = Header.create ~table_offset ~current_size  () in

       let current_size = Int64.(shift_left (of_int header.Header.max_table_entries) (header.Header.block_size_sectors_shift + sector_shift)) in
       let footer = Footer.create ~data_offset ~current_size ~disk_type:Disk_type.Dynamic_hard_disk () in
       let bat_buffer = File.alloc (BAT.sizeof_bytes header) in
       let bat = BAT.of_buffer header bat_buffer in

       let sizeof_bat = BAT.sizeof_bytes header in

       let sizeof_bitmap = Header.sizeof_bitmap header in
       (* We'll always set all bitmap bits *)
       let bitmap = File.alloc sizeof_bitmap in
       for i = 0 to sizeof_bitmap - 1 do
         Cstruct.set_uint8 bitmap i 0xff
       done;

       let sizeof_data = 1 lsl (header.Header.block_size_sectors_shift + sector_shift) in

       (* Calculate where the first data block will go. Note the sizeof_bat is already
          rounded up to the next sector boundary. *)
       let first_block = Int64.(table_offset ++ (of_int sizeof_bat)) in
       let next_byte = ref first_block in
       let blocks = header.Header.max_table_entries in
       for i = 0 to blocks - 1 do
         BAT.set bat i (Int64.(to_int32(!next_byte lsr sector_shift)));
         next_byte := Int64.(!next_byte ++ (of_int sizeof_bitmap) ++ (of_int sizeof_data))
       done;

       let rec write_sectors buf from andthen =
         return(Cons(Sectors buf, andthen)) in
       let rec block i andthen =
         if i >= blocks
         then andthen ()
         else
           let length = Int64.(shift_left 1L header.Header.block_size_sectors_shift) in
           let sector = Int64.(shift_left (of_int i) header.Header.block_size_sectors_shift) in
           return (Cons(Sectors bitmap, fun () -> return (Cons(Copy(t.Raw.handle, sector, length), fun () -> block (i+1) andthen)))) in

       assert(Footer.sizeof = 512);
       assert(Header.sizeof = 1024);

       let buf = File.alloc (max Footer.sizeof (max Header.sizeof sizeof_bat)) in
       let (_: Footer.t) = Footer.marshal buf footer in
       coalesce_request None (return (Cons(Sectors(Cstruct.sub buf 0 Footer.sizeof), fun () ->
         let (_: Header.t) = Header.marshal buf header in
         write_sectors (Cstruct.sub buf 0 Header.sizeof) 0 (fun () ->
           return(Cons(Empty 1L, fun () ->
             BAT.marshal buf bat;
             write_sectors (Cstruct.sub buf 0 sizeof_bat) 0 (fun () ->
               let (_: Footer.t) = Footer.marshal buf footer in
               block 0 (fun () ->
                 return(Cons(Sectors(Cstruct.sub buf 0 Footer.sizeof), fun () -> return End))
               )
             )
          ))
        )
       ))) >>= fun elements ->
       let metadata = Int64.of_int ((2 * Footer.sizeof + Header.sizeof + sizeof_bat + sizeof_bitmap * blocks)) in
       let size = { empty with metadata; total = current_size; copy = current_size } in
       return { elements; size } 

     let raw t =
       File.get_file_size t.filename >>= fun bytes ->
       (* round up to the next full sector *)
       let open Int64 in
       let bytes = roundup_sector bytes in
       let size = {
         total = bytes;
         metadata = 0L;
         empty = 0L;
         copy = bytes;
       } in
       let elements = Cons(Copy(t.handle, 0L, bytes lsr sector_shift), fun () -> return End) in
       return { size; elements }
   end
end
