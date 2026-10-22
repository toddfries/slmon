# Build the imsg and dish extensions, then the regress suite.

.PHONY: all regress clean install

PREFIX ?= /usr/local
DESTDIR ?=
ARCH != perl -MConfig -e 'print $$Config{archname}'
SITE = ${DESTDIR}${PREFIX}/libdata/perl5/site_perl

all:
	cd ext/imsg && ${MAKE}
	cd ext/dishbridge && ${MAKE}

regress: all
	cd regress && ${MAKE} regress

clean:
	cd ext/imsg && ${MAKE} clean
	cd ext/dishbridge && ${MAKE} clean
	cd regress && ${MAKE} clean

install: all
	install -d ${DESTDIR}${PREFIX}/sbin
	install -d ${SITE}/SLMON/DB
	install -d ${SITE}/${ARCH}/auto/SLMON/Dish
	install -d ${SITE}/${ARCH}/auto/SLMON/Imsg
	install -d ${DESTDIR}${PREFIX}/man/man5
	install -d ${DESTDIR}${PREFIX}/man/man8
	install -d ${DESTDIR}${PREFIX}/share/examples/slmon
	install -d ${DESTDIR}/etc/rc.d
	install -m 0555 bin/sld bin/slctl ${DESTDIR}${PREFIX}/sbin
	install -m 0444 lib/SLMON.pm ${SITE}/SLMON.pm
	install -m 0444 lib/SLMON/*.pm ${SITE}/SLMON
	install -m 0444 lib/SLMON/DB/*.pm ${SITE}/SLMON/DB
	install -m 0555 blib/auto/SLMON/Dish/Dish.so ${SITE}/${ARCH}/auto/SLMON/Dish/Dish.so
	install -m 0555 blib/auto/SLMON/Imsg/Imsg.so ${SITE}/${ARCH}/auto/SLMON/Imsg/Imsg.so
	install -m 0444 man/man8/sld.8 man/man8/slctl.8 ${DESTDIR}${PREFIX}/man/man8
	install -m 0444 man/man5/sl.conf.5 ${DESTDIR}${PREFIX}/man/man5
	install -m 0444 etc/sl.conf ${DESTDIR}${PREFIX}/share/examples/slmon/sl.conf
	install -m 0555 rc.d/sld ${DESTDIR}/etc/rc.d/sld
