# libc imsg only. No libgrpc.
CC?= cc
CFLAGS += -O2 -fPIC -Wall
PERLINC!= perl -MConfig -e 'print "-I$$Config{archlib}/CORE $$Config{ccflags}"'
TYPEMAP!= perl -MConfig -e 'print "$$Config{privlib}/ExtUtils/typemap"'

all: ../../blib/auto/SLMON/Imsg/Imsg.so

Imsg.c: Imsg.xs
	xsubpp -typemap ${TYPEMAP} Imsg.xs > Imsg.c.tmp && mv Imsg.c.tmp Imsg.c

Imsg.o: Imsg.c
	${CC} ${CFLAGS} ${PERLINC} -c Imsg.c

../../blib/auto/SLMON/Imsg/Imsg.so: Imsg.o
	mkdir -p ../../blib/auto/SLMON/Imsg
	${CC} -shared -fPIC -o $@ Imsg.o -lutil

clean:
	rm -f Imsg.c Imsg.o ../../blib/auto/SLMON/Imsg/Imsg.so

.PHONY: all clean
