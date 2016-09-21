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
