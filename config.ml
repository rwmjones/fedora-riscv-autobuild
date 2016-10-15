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

(* Read the README file first! *)

open Printf

(* Maximum number of parallel builds to run.
 *
 * The main limiting factor may be disk space, since each build
 * requires a copy of the disk which may be several GB.
 *)
let max_builds = 8

(* Fedora release we are building for. *)
let releasever = 25
let new_builds_tag = sprintf "f%d-updates-candidate" releasever

(* Poll interval (in seconds). *)
let poll_interval = 10 * 60

(* Blacklisted packages that we ignore if they appear in Koji. *)
let blacklist = [
  "kernel";
  "glibc";
  "binutils";
  "gcc";
  "gdb";

  (* Some massive packages are excluded here. *)
  "0ad-data";
  "FlightGear-data";
  "alienarena";
  "berusky2-data";
  "btbuilder";
  "chromium";
  "chromium-native_client";
  "libreoffice";
]
