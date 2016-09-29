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

open Unix
open Printf

open Utils
open Config

type source = Koji | Manual

type package = {
  source : source;              (* Source of the package. *)
  nvr : string;                 (* Full RPM NVR as a single string. *)
  name : string;                (* Just the source package name. *)
  version : string;             (* Version. *)
  release : string;             (* Release. *)
}
type build = {
  pkg : package;                (* The package being built. *)
  pid : int;                    (* PID of qemu process. *)
  disk : string;                (* Path to the disk image. *)
  logdir : string;              (* Path to the log directory. *)
  bootlog : string;             (* Path to the boot.log file. *)
  srpm : string;                (* Path to the SRPM file. *)
}

type build_status =
  | Successful of package * string (* build.log *)
  | Build_failure of package * string (* build.log *)
  | Missing_deps of package * string (* root.log *)
  | Unknown_failure of package * string (* boot.log *)

let quote = Filename.quote
let (//) = Filename.concat

let nvr_to_package =
  let rex = Pcre.regexp "^(.*?)-([^-]+)-([^-]+)$" in
  fun source nvr ->
    try
      let subs = Pcre.exec ~rex nvr in
      { source = source;
        nvr = nvr;
        name = Pcre.get_substring subs 1;
        version = Pcre.get_substring subs 2;
        release = Pcre.get_substring subs 3 }
    with Not_found ->
         failwith (sprintf "bad NVR: %s" nvr)

(* Boot a disk image in qemu, running it as a background process.
 * Returns the process ID.
 *)
let boot_vm disk bootlog =
  let cmd = [| "qemu-system-riscv"; "-m"; "4G";
               "-kernel"; "/usr/bin/bbl";
               "-append"; "vmlinux";
               "-drive"; sprintf "file=%s,format=raw" disk;
               "-nographic" |] in

  let devnull_fd = openfile "/dev/null" [ O_RDONLY ] 0 in
  let bootlog_fd =
    openfile bootlog [ O_WRONLY; O_CREAT; O_TRUNC; O_NOCTTY ] 0o644 in

  let pid = fork () in
  if pid = 0 then (
    dup2 devnull_fd stdin;
    dup2 bootlog_fd stdout;
    dup2 bootlog_fd stderr;
    execvp "qemu-system-riscv" cmd
  );

  close devnull_fd;
  close bootlog_fd;

  pid

(* Get the BuildRequires of an SRPM as a list of package names.  Not
 * exactly made easy by the hideous output of dnf.
 *)
let get_build_requires srpm =
  let cmd = sprintf "dnf provides `rpm -qRp %s` | grep -vE \"^(Last|Repo)[[:space:]]\" | grep -v \"^ \" | grep -v \"^$\" | awk '{print $1}' | sort -u"
                    srpm in
  let chan = open_process_in cmd in
  let ret = ref [] in
  (try while true do ret := input_line chan :: !ret done
   with End_of_file -> ());
  match close_process_in chan with
  | WEXITED 0 ->
     let ret = List.rev !ret in
     (* Just want the package names ... *)
     List.map (fun nvr ->
                 (nvr_to_package Manual (* not used *) nvr).name) ret
  | WEXITED _ | WSIGNALED _ | WSTOPPED _ ->
     failwith (sprintf "%s: failed" cmd)

(* Write the /init script that controls the build inside the VM. *)
let init_script build srpm_in_disk =
  let build_requires = get_build_requires build.srpm in

  let tm = gmtime (gettimeofday ()) in
  let month, day, hour, min, year =
    tm.tm_mon+1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_year+1900 in

  let hostname =
    match build.pkg.source with
    | Koji -> "riscv-autobuild-koji"
    | Manual -> "riscv-autobuild-manual" in

  let init = sprintf "\
#!/bin/bash -

# Set up the PATH.
PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin
export PATH

# Root filesystem is mounted as ro, remount it as rw.
mount -o remount,rw /

# Mount standard filesystems.
mount -t proc /proc /proc
mount -t sysfs /sys /sys
mount -t tmpfs -o \"nosuid,size=20%%,mode=0755\" tmpfs /run
mkdir -p /run/lock

# XXX devtmpfs

# Initialize dynamic linker cache.
ldconfig /usr/lib64 /usr/lib /lib64 /lib

# There is no hardware clock.  As we rebuild this init script for
# each build, we can insert the approximate current time.
# The format is MMDDhhmmCCYY
date -u '%02d%02d%02d%02d%04d'

hostname %s
echo riscv-autobuild.fedoraproject.org > /etc/hostname

echo
echo \"This is the Fedora RISC-V autobuilder\"
echo \"Current package: %s\"
echo

# Cleanup function called on failure or exit.
cleanup ()
{
    set +e
    # Sync disks and shut down.
    sync
    sleep 5
    sync
    mount -o remount,ro / >&/dev/null
    poweroff
}
trap cleanup INT QUIT TERM EXIT ERR

# Display list of repositories:
tdnf repolist
tdnf clean all
tdnf makecache

# Pick up any updated packages:
tdnf -y update --best

set -e

# Install the basic build environment.  This is no longer included
# in stage4-disk.img, so we have to install these packages ourselves.
# See also buildsys-build in comps.xml
tdnf -y install \
    bash \
    bzip2 \
    coreutils \
    cpio \
    diffutils \
    elfutils \
    fedora-release \
    findutils \
    gawk \
    hack-gcc \
    glibc-headers \
    grep \
    gzip \
    info \
    make \
    patch \
    redhat-rpm-config \
    rpm-build \
    sed \
    shadow-utils \
    tar \
    unzip \
    util-linux \
    which \
    xz

# XXX Required after installing hack-gcc.  Not necessary once
# we use proper gcc package.
source /etc/profile.d/gcc.sh
pushd /usr/bin
ln -s gcc cc
popd

# Hack to make iconv command work.
# Remove this when we have fixed glibc.
pushd /usr/lib
ln -s ../lib64/gconv
popd

# Hack to make libcrypt.so.
# Remove this when we have fixed glibc.
pushd /lib64
ln -s ../lib/libcrypt-2.24.so
ln -s libcrypt-2.24.so libcrypt.so
popd

# Hack to fix python{2,3}-devel.
# Remove this when fixed in the python package.
for d in /usr/include/python2.7 /usr/include/python3.5m; do
    mkdir -p $d
    pushd $d
    ln -sf pyconfig-32.h pyconfig-64.h
    popd
done

# Install the package BuildRequires.
#
# tdnf doesn't do build requirements.  'tdnf install' *only* handles
# pure package names, not even virtual provides like 'perl(Foo)'.
# So we have had to compute the BRs offline on the host and place
# the package names here.  This means that we get the x86_64 BRs
# which could be slightly different from the riscv64 BRs.
#
# XXX When we have compiled full dnf, replace this with
# 'dnf builddep' command.
if %s; then tdnf -y install --best %s >& /root.log; fi

# Make a build directory which isn't root.
# Required to work around:
# /usr/lib/rpm/debugedit: -b arg has to be either the same length as -d arg, or more than 1 char longer
# and:
# https://bugzilla.redhat.com/show_bug.cgi?id=757089
# when building debuginfo.
mkdir -p /builddir/build

# Set _topdir to point to the build directory.
# Also works around a cmake bug:
# https://github.com/rwmjones/fedora-riscv/commit/68780a3e928b01f9012f5e8cd014ff636a7467b3
cat > /.rpmmacros <<EOF
%%_topdir /builddir/build
EOF

# Build the package.
rpmbuild --rebuild %s >& /build.log

# If we got here, the build was successful.  Drop a file into
# the root directory so we know.
touch /buildok

# cleanup() is called automatically here.
"
    month day hour min year
    hostname
    build.pkg.nvr
    (string_of_bool (build_requires <> []))
    (String.concat " " (List.map quote build_requires))
    srpm_in_disk in

  init

(* Download a source RPM from Koji. *)
let download_srpm nvr =
  let local_filename = sprintf "tmp/%s.src.rpm" nvr in
  if Sys.file_exists local_filename then
    Some local_filename
  else (
    let cmd = sprintf "cd tmp && koji download-build -a src %s" (quote nvr) in
    if Sys.command cmd == 0 then
      Some local_filename
    else
      None (* Download failed. *)
  )

(* Just a wrapper around the 'cp' command. *)
let copy_file src dst =
  let cmd = sprintf "cp %s %s" (quote src) (quote dst) in
  if Sys.command cmd <> 0 then failwith (sprintf "%s: failed" cmd)

(* This code is basically copied from
 * /usr/share/doc/ocaml-libguestfs-devel/inspect_vm.ml
 *)
let open_disk ?readonly disk =
  let g = new Guestfs.guestfs () in
  g#add_drive_opts disk ~format:"raw" ?readonly;
  g#launch ();

  let roots = g#inspect_os () in
  if Array.length roots == 0 || Array.length roots > 1 then
    failwith "could not open VM disk image";
  let root = roots.(0) in
  let mps = g#inspect_get_mountpoints root in
  let cmp (a,_) (b,_) =
    compare (String.length a) (String.length b) in
  let mps = List.sort cmp mps in
  List.iter (
    fun (mp, dev) ->
      try g#mount dev mp
      with Guestfs.Error msg -> eprintf "%s (ignored)\n" msg
  ) mps;

  g

(* Start a new build.  Returns the build object. *)
let start_build pkg =
  (* NVR as a single string: *)
  let nvr = pkg.nvr in
  (* Split NVR of the RPM: *)
  let name = pkg.name in
  let version = pkg.version in
  let release = pkg.release in

  let srpm = download_srpm nvr in
  match srpm with
  | None -> None
  | Some srpm ->
     (* Create the build directory. *)
     let logdir = sprintf "logs/%s/%s-%s" name version release in
     let cmd = sprintf "mkdir -p %s" (quote logdir) in
     if Sys.command cmd <> 0 then failwith (sprintf "%s: failed" cmd);

     (* If we already built this package successfully, don't
      * try it again.
      *)
     if Sys.file_exists (sprintf "%s/buildok" logdir) then (
       message "%s already built" nvr;
       None
     )
     else (
       (* Take an atomic full copy of the stage4 disk image. *)
       let disk = sprintf "tmp/%s-disk.img" name in
       copy_file "stage4-disk.img" disk;

       let g = open_disk disk in

       (* Copy the source RPM into the disk. *)
       let srpm_in_disk = sprintf "/var/tmp/%s.src.rpm" nvr in
       g#upload srpm srpm_in_disk;

       (* Copy the previously built RPMs into the disk and set up
        * a local repo for tdnf to use.
        *)
       g#copy_in "RPMS" "/var/tmp";
       g#write "/etc/yum.repos.d/local.repo" "\
[local]
name=Local RPMS
baseurl=file:///var/tmp/RPMS
enabled=1
gpgcheck=0
";

       let build =
         { pid = 0; bootlog = ""; (* see below *)
           pkg = pkg; srpm = srpm; logdir = logdir; disk = disk } in

       (* Create an init script and insert it into the disk image. *)
       let init = init_script build srpm_in_disk in
       g#write "/init" init;
       g#chmod 0o755 "/init";

       (* Close the disk image. *)
       g#shutdown ();
       g#close ();

       message "%s build starting" nvr;

       (* Boot the VM. *)
       let bootlog = sprintf "%s/boot.log" logdir in
       let pid = boot_vm disk bootlog in

       Some { build with pid = pid; bootlog = bootlog }
     )

let createrepo () =
  let cmd = "make repo" in
  if Sys.command cmd <> 0 then failwith (sprintf "%s: failed" cmd)

let rsync () =
  let cmd = "make rsync" in
  if Sys.command cmd <> 0 then failwith (sprintf "%s: failed" cmd)

(* Finish off a build (it has already been reaped by waitpid). *)
let finish_build build =
  let g = open_disk ~readonly:true build.disk in

  (* Save root.log if it was created. *)
  let got_root_log =
    try g#download "/root.log" (build.logdir ^ "/root.log"); true
    with Guestfs.Error _ -> false in

  (* Save build.log if it was created. *)
  let got_build_log =
    try g#download "/build.log" (build.logdir ^ "/build.log"); true
    with Guestfs.Error _ -> false in

  (* Did the build finish successfully? *)
  let buildok =
    if g#exists "/buildok" then (
      (* We save a flag in the directory so we don't try to
       * build the package again.
       *)
      close_out (open_out (sprintf "%s/buildok" build.logdir));

      (* Save the RPMs and SRPM. *)
      g#copy_out "/builddir/build/RPMS" ".";
      (* rpmbuild --rebuild doesn't write out an SRPM, so copy
       * the one from Koji instead.
       *)
      (*g#copy_out "/builddir/build/SRPMS" ".";*)
      copy_file build.srpm "SRPMS/";

      (* We have a new RPM, so recreate the repodata. *)
      createrepo ();
      true
    )
    else false in

  g#close ();

  (* Delete the disk image. *)
  unlink build.disk;

  (* Determine the build status. *)
  let build_status =
    match got_root_log, got_build_log, buildok with
    | _, _, true ->
       Successful (build.pkg, build.logdir // "build.log")
    | _, true, false ->
       Build_failure (build.pkg, build.logdir // "build.log")
    | true, false, false ->
       Missing_deps (build.pkg, build.logdir // "root.log")
    | _ ->
       Unknown_failure (build.pkg, build.logdir // "boot.log") in

  (* Print the build status. *)
  (match build_status with
   | Successful (pkg, logfile) ->
      message ~col:ansi_green "COMPLETED: %s" pkg.nvr
   | Build_failure (pkg, logfile) ->
      message ~col:ansi_red "FAIL: Build failure: %s (see %s)"
              pkg.nvr logfile
   | Missing_deps (pkg, logfile) ->
      message ~col:ansi_magenta (* this is expected, not really a failure *)
              "MISSING DEPS: %s (see %s)" pkg.nvr logfile
   | Unknown_failure (pkg, logfile) ->
      message ~col:ansi_red "FAIL: Unknown failure: %s (see %s)"
              pkg.nvr logfile
  );

  (* Add the build status to logs/status.html *)
  let chan = open_out_gen [Open_wronly; Open_append; Open_creat; Open_text]
                          0o644 "logs/status.html" in
  fprintf chan "<br>\n";
  (match build_status with
   | Successful (pkg, logfile) ->
      fprintf chan "<span style=\"color:green;\">COMPLETED:</span> %s (<a href=\"../%s\">build.log</a>)\n"
              pkg.nvr logfile
   | Build_failure (pkg, logfile) ->
      fprintf chan "<span style=\"color:red;\">FAIL:</span> Build failure: %s (<a href=\"../%s\">build.log</a>)\n"
              pkg.nvr logfile
   | Missing_deps (pkg, logfile) ->
      fprintf chan "<span style=\"color:purple;\">MISSING DEPS:</span> %s (<a href=\"../%s\">root.log</a>)\n"
              pkg.nvr logfile
   | Unknown_failure (pkg, logfile) ->
      fprintf chan "<span style=\"color:red;\">FAIL:</span> Unknown failure: %s (<a href=\"../%s\">boot.log</a>)\n"
              pkg.nvr logfile
  );
  close_out chan;

  (* We should have at least a boot.log, and maybe much more, so rsync. *)
  rsync ()

module StringSet = Set.Make (String)

(* Return the latest builds from Koji.
 * There's not actually a way to do this, so this saves the
 * list of current builds to a local file, and returns the
 * differences.
 *)
let get_latest_builds () =
  let ret = ref [] in

  (* Only run the koji command at most once every poll_interval, to
   * avoid overloading Koji and because there's no reason to run
   * it more often than that.  It also makes the implementation of
   * the 'loop' function below simpler since it lets us call this
   * function whenever we want.
   *)
  let statbuf =
    try Some (stat "koji-builds")
    with Unix_error (ENOENT, _, _) -> None in
  let age =
    match statbuf with
    | None -> max_float
    | Some { st_mtime = mtime } -> gettimeofday () -. mtime in

  if age >= float_of_int (poll_interval - 5) then (
    message "Getting latest packages from Koji ...";
    let cmd =
      sprintf "koji latest-pkg --quiet --all %s | awk '{print $1}' > koji-builds.new"
              new_builds_tag in
    if Sys.command cmd <> 0 then
      eprintf "warning: koji command failed\n%!"
    else (
      if statbuf <> None (* "koji-builds" exists *) then (
        (* Read the old file and the new file and return any new packages. *)
        let read_koji_builds filename =
          let chan = open_in filename in
          let set = ref StringSet.empty in
          (try while true do set := StringSet.add (input_line chan) !set done
           with End_of_file -> ());
          close_in chan;
          !set
        in

        let olds = read_koji_builds "koji-builds" in
        let news = read_koji_builds "koji-builds.new" in

        StringSet.iter (
          fun nvr ->
            if not (StringSet.mem nvr olds) then (
              let pkg = (nvr_to_package Koji) nvr in
              ret := pkg :: !ret
            )
        ) news;
      );
      rename "koji-builds.new" "koji-builds";
    )
  );

  !ret

(* Return a list of all packages, used for mass rebuilds. *)
let get_mass_rebuild_packages () =
  message "Getting list of all Fedora packages from Koji ...";
  let cmd =
    sprintf "koji latest-pkg --quiet --all %s | awk '{print $1}' > koji-builds"
            new_builds_tag in
  if Sys.command cmd <> 0 then failwith (sprintf "%s: failed" cmd);

  let read_koji_builds filename =
    let chan = open_in filename in
    let ret = ref [] in
    (try while true do ret := input_line chan :: !ret done
     with End_of_file -> ());
    close_in chan;
    List.rev !ret
  in

  let nvrs = read_koji_builds "koji-builds" in
  let packages = List.map (nvr_to_package Koji) nvrs in
  packages

(* Remove packages which are on the blacklist. *)
let not_blacklisted { name = name } = not (List.mem name blacklist)

(* Parse the command line. *)
let mass_rebuild = ref false
let argspec =
  Arg.align [
    "--mass-rebuild", Arg.Set mass_rebuild, "Rebuild every package";
  ]
let packages_from_command_line = ref []
let anon_fun str =
  packages_from_command_line := str :: !packages_from_command_line
let usage_msg =
  "riscv-autobuild : auto package builder for Fedora/RISC-V

SUMMARY
  ./riscv-autobuild
     Pick up new packages from Koji and try rebuilding them.

  ./riscv-autobuild NVR [NVR ...]
     Build specified packages (list their NVR(s) on the command line).

  ./riscv-autobuild --mass-rebuild
     Try to build every package in Fedora.

OPTIONS"
let () = Arg.parse argspec anon_fun usage_msg
let mass_rebuild = !mass_rebuild
let packages_from_command_line =
  let nvrs = List.rev !packages_from_command_line in
  List.map (nvr_to_package Manual) nvrs

(* The main loop.  See README for how this works. *)

(* The running list is a map from RPM name to build.  Storing the
 * RPM name as the key prevents us running two builds of the
 * same package at the same time.
 *)
module StringMap = Map.Make (String)

let rec loop packages running =
  (* If we have no packages, look for more. *)
  let packages =
    if packages_from_command_line <> [] || mass_rebuild then
      packages
    else
      List.filter not_blacklisted (get_latest_builds ()) in

  (* Check if any builds have finished, and reap them. *)
  let rec reap_builds running = function
    | [] -> running
    | (name, build) :: rest ->
       let pid, _ = waitpid [WNOHANG] build.pid in
       let running =
         if pid > 0 then (
           finish_build build;
           StringMap.remove name running
         )
         else running in
       reap_builds running rest
  in
  let running = reap_builds running (StringMap.bindings running) in

  let nr_running = StringMap.cardinal running in

  message ~col:ansi_blue "Running: %d (max: %d) Waiting to start: %d"
          nr_running max_builds (List.length packages);

  let packages, running =
    if nr_running > 0 && packages = [] then (
      (* If some builds are running but there are no packages waiting
       * to be added, we want to go back and check if the builds have
       * finished.  However do a short sleep first so we're not
       * busy-waiting.
       *)
      sleep 10;
      (packages, running)
    )
    else if nr_running >= max_builds || packages = [] then (
      (* If we've maxed out the number of builds, or there are no
       * packages to build, sleep for a bit.
       *)
      message "Sleeping for %d seconds ..." poll_interval;
      sleep poll_interval;
      (packages, running)
    )
    else (
      (* Take packages from the list and start building them. *)
      let rec start_builds packages running =
        if packages = [] || StringMap.cardinal running >= max_builds then
          (packages, running) (* no more packages or too many builds *)
        else (
          let pkg, packages = List.hd packages, List.tl packages in
          let name = pkg.name in
          (* If the package is already building, skip it and keep looping. *)
          if StringMap.mem name running then
            start_builds packages running
          else (
            let build = start_build pkg in
            let running =
              match build with
              | None -> running
              | Some build -> StringMap.add name build running in
            start_builds packages running
          )
        )
      in

      start_builds packages running
    ) in

  loop packages running

let () =
  let packages =
    if packages_from_command_line <> [] then
      packages_from_command_line
    else if mass_rebuild then
      List.filter not_blacklisted (get_mass_rebuild_packages ())
    else [] in
  let running = StringMap.empty in
  loop packages running
