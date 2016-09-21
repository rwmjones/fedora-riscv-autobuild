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

type package = {
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

let quote = Filename.quote

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

  pid

(* Write the /init script that controls the build inside the VM. *)
let init_script name nvr srpm =
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

# There is no hardware clock, just ensure the date is not miles out.
date `date -r /usr/bin +%%m%%d%%H%%M%%Y`

hostname riscv-autobuild
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
    mount.static -o remount,ro / >&/dev/null
    poweroff
}
trap cleanup INT QUIT TERM EXIT ERR

set -e

# Install the build requirements.
#
# tdnf cannot handle versioned requirements, so just try to install
# any package with the same name here.  The rpmbuild command will
# do more detailed analysis and catch missing versioned deps.
#
# Also some packages have no BuildRequires, so handle that too.
brs=\"$(
    rpm -qRp %s |
        awk '{print $1}' |
        grep -v '^rpmlib(' ||:
    )\"
if [ -n \"$brs\" ]; then
    tdnf --releasever %d install $brs >& /root.log
fi

# Build the package.
rpmbuild --rebuild %s >& /build.log

# If we got here, the build was successful.  Drop a file into
# the root directory so we know.
touch /buildok

# cleanup() is called automatically here.
" nvr srpm releasever srpm in
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

       (* Create an init script and insert it into the disk image. *)
       let init = init_script name nvr srpm_in_disk in
       g#write "/init" init;
       g#chmod 0o755 "/init";

       (* Close the disk image. *)
       g#shutdown ();
       g#close ();

       message "%s build starting" nvr;

       (* Boot the VM. *)
       let bootlog = sprintf "%s/boot.log" logdir in
       let pid = boot_vm disk bootlog in

       Some { pid = pid; pkg = pkg; srpm = srpm;
              logdir = logdir; bootlog = bootlog;
              disk = disk }
     )

let createrepo () =
  let cmd = "cd RPMS && createrepo ." in
  if Sys.command cmd <> 0 then failwith (sprintf "%s: failed" cmd)

let add_rpms_to_stage4 () =
  (* XXX What needs to be done here:
   * (1) Upload the RPMS directory including the repodata into the
   * stage4-disk.img file.
   * (2) Create /etc/yum.repos.d/local.repo pointing to this directory.
   * (3) Check that tdnf can use this repo.
   *)
  ()

let rsync () =
  (* Don't use --delete.  Let the files accumulate at the remote side. *)
  let cmd = "rsync -av RPMS SRPMS logs fedorapeople.org:/project/risc-v" in
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
      g#copy_out "/rpmbuild/RPMS" ".";
      (* rpmbuild --rebuild doesn't write out an SRPM, so copy
       * the one from Koji instead.
       *)
      (*g#copy_out "/rpmbuild/SRPMS" ".";*)
      copy_file build.srpm "SRPMS/";

      (* We have a new RPM, so recreate the repository and add it to
       * the stage4 master disk image.
       *)
      createrepo ();
      add_rpms_to_stage4 ();
      true
    )
    else false in

  g#close ();

  (* Delete the disk image. *)
  unlink build.disk;

  (* Print the build status. *)
  (match got_root_log, got_build_log, buildok with
   | _, _, true ->
      message ~col:ansi_green "COMPLETED: %s" build.pkg.nvr
   | _, true, false ->
      message ~col:ansi_red "FAIL: Build failure: %s (see %s/build.log)"
              build.pkg.nvr build.logdir
   | true, false, false ->
      message ~col:ansi_magenta (* this is expected, not really a failure *)
              "MISSING DEPS: %s (see %s/root.log)"
              build.pkg.nvr build.logdir
   | _ ->
      message ~col:ansi_red "FAIL: Unknown failure: %s (see %s/boot.log)"
              build.pkg.nvr build.logdir
  );

  (* We should have at least a boot.log, and maybe much more, so rsync. *)
  rsync ()

let nvr_to_package =
  let rex = Pcre.regexp "^(.*?)-(\\d.*)-([^-]+)$" in
  fun nvr ->
    try
      let subs = Pcre.exec ~rex nvr in
      Some { nvr = nvr;
             name = Pcre.get_substring subs 1;
             version = Pcre.get_substring subs 2;
             release = Pcre.get_substring subs 3 }
    with Not_found -> None

module StringSet = Set.Make (String)

(* Return the latest builds from Koji.
 * There's not actually a way to do this, so this saves the
 * list of current builds to a local file, and returns the
 * differences.
 *)
let get_latest_builds () =
  let ret = ref [] in

  (* Only run the koji command at most once every 10 minutes, to
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

  if age > 600. then (
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
              let pkg = nvr_to_package nvr in
              match pkg with
              | None -> ()
              | Some pkg -> ret := pkg :: !ret
            )
        ) news;
      );
      rename "koji-builds.new" "koji-builds";
    )
  );

  !ret

(* The main loop.  See README for how this works. *)

(* The running list is a map from RPM name to build.  Storing the
 * RPM name as the key prevents us running two builds of the
 * same package at the same time.
 *)
module StringMap = Map.Make (String)

let packages_from_command_line = Array.length Sys.argv >= 2

let rec loop packages running =
  (* If we have no packages, look for more. *)
  let packages =
    if packages = [] && not packages_from_command_line then
      get_latest_builds ()
    else
      packages in

  (* Check if any builds have finished, and reap them. *)
  let rec reap_builds running =
    let build = try Some (StringMap.choose running) with Not_found -> None in
    match build with
    | None -> running
    | Some (name, build) ->
       let pid, _ = waitpid [WNOHANG] build.pid in
       let running =
         if pid > 0 then (
           finish_build build;
           StringMap.remove name running
         )
         else running in
       reap_builds running
  in
  let running = reap_builds running in

  let nr_running = StringMap.cardinal running in

  message ~col:ansi_blue "Running: %d (max: %d) Waiting to start: %d"
          nr_running max_builds (List.length packages);

  let packages, running =
    (* If we've maxed out the number of builds, or there are no
     * packages to build, sleep for a bit.
     *)
    if nr_running >= max_builds || packages = [] then (
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
    if packages_from_command_line then (
      let len = Array.length Sys.argv - 1 in
      let nvrs = Array.sub Sys.argv 1 len in
      let nvrs = Array.to_list nvrs in
      filter_map nvr_to_package nvrs
    )
    else [] in
  let running = StringMap.empty in
  loop packages running
