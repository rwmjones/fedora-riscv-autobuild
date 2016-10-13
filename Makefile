OCAMLC      = ocamlc
OCAMLCFLAGS = -I +unix -I +pcre -I +guestfs -warn-error CDEFLMPSUVYZX-3
OCAMLCLIBS  = unix.cma pcre.cma mlguestfs.cma 

all:	riscv-autobuild

riscv-autobuild: config.cmo utils.cmo autobuild.cmo
	$(OCAMLC) $(OCAMLCFLAGS) $(OCAMLCLIBS) $^ -o $@

.ml.cmi:
	$(OCAMLC) $(OCAMLCFLAGS) -c $< -o $@

.ml.cmo:
	$(OCAMLC) $(OCAMLCFLAGS) -c $< -o $@

.SUFFIXES: .ml .cmi .cmo

# Dependencies.
include .depend

depend:
	ocamldep *.ml > .depend

clean:
	rm -f riscv-autobuild
	rm -f *.cmo *.cmi
	rm -f *~
	rm -f tmp/*-disk.img

veryclean: clean
	rm -f tmp/*.src.rpm

distclean: veryclean
	rm -f vmlinux stage4-disk.img

# The 'make repo' and 'make rsync' rules are also run from
# the autobuilder.

repo:
	cd RPMS && createrepo -g ../comps-f25.xml .

rsync:
#	Don't use --delete.  Let the files accumulate at the remote side.
	rsync -av SRPMS logs fedorapeople.org:/project/risc-v
	rsync -av RPMS/noarch fedorapeople.org:/project/risc-v/RPMS
	rsync -av RPMS/riscv64 fedorapeople.org:/project/risc-v/RPMS
#	... except here because we want a single repodata set.
	rsync -av --delete RPMS/repodata fedorapeople.org:/project/risc-v/RPMS
