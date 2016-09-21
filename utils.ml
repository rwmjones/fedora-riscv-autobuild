(* Fedora/RISC-V autobuilder.
 * Copyright (C) 2016 Red Hat Inc.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *)

open Printf

let rec filter_map f = function
  | [] -> []
  | x :: xs ->
      match f x with
      | Some y -> y :: filter_map f xs
      | None -> filter_map f xs

(* ANSI terminal colours. *)
let istty chan =
  Unix.isatty (Unix.descr_of_out_channel chan)

let ansi_green ?(chan = stdout) () =
  if istty chan then output_string chan "\x1b[0;32m"
let ansi_red ?(chan = stdout) () =
  if istty chan then output_string chan "\x1b[1;31m"
let ansi_blue ?(chan = stdout) () =
  if istty chan then output_string chan "\x1b[1;34m"
let ansi_magenta ?(chan = stdout) () =
  if istty chan then output_string chan "\x1b[1;35m"
let ansi_restore ?(chan = stdout) () =
  if istty chan then output_string chan "\x1b[0m"

(* Print message, followed by newline and flushing the output channel. *)
let message ?col ?(chan = stdout) fs =
  (* This annotation lets type inference figure out that we need
   * to call the function with an optional ?chan not a required ~chan.
   *)
  ignore (col : (?chan:out_channel -> unit -> unit) option);

  let display str =
    (match col with None -> () | Some col -> col ~chan ());
    fprintf chan "%s" str;
    (match col with None -> () | Some _ -> ansi_restore ~chan ());
    output_char chan '\n';
    Pervasives.flush chan;
  in
  ksprintf display fs
