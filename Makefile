# Build the imsg extension. The dish XS module links libgrpc++ and is
# left unbuilt unless WITH_DISH_XS=yes. The default client is Perl.

.PHONY: all man regress clean install

PREFIX ?= /usr/local
DESTDIR ?=
WITH_DISH_XS ?= no
ARCH != perl -MConfig -e 'print $$Config{archname}'
SITE = ${DESTDIR}${PREFIX}/libdata/perl5/site_perl

MAN8 = sld.8 slctl.8
MAN5 = sl.conf.5

all: man
	cd ext/imsg && ${MAKE}
	if [ "${WITH_DISH_XS}" = yes ]; then cd ext/dishbridge && ${MAKE}; fi

man: ${MAN8:S/$/.md/:S/^/man\/man8\//} ${MAN5:S/$/.md/:S/^/man\/man5\//}

.for p in ${MAN8}
man/man8/${p}.md: man/man8/${p}
	cd man/man8 && mandoc -T markdown ${p} > ${p}.md
.endfor

.for p in ${MAN5}
man/man5/${p}.md: man/man5/${p}
	cd man/man5 && mandoc -T markdown ${p} > ${p}.md
.endfor

regress: all
	cd regress && ${MAKE} regress

clean:
	cd ext/imsg && ${MAKE} clean
	cd ext/dishbridge && ${MAKE} clean
	cd regress && ${MAKE} clean

install: all
	install -d ${DESTDIR}${PREFIX}/sbin
	install -d ${SITE}/SLMON/DB
	install -d ${SITE}/${ARCH}/auto/SLMON/Imsg
	install -d ${DESTDIR}${PREFIX}/man/man5
	install -d ${DESTDIR}${PREFIX}/man/man8
	install -d ${DESTDIR}${PREFIX}/share/examples/slmon
	install -m 0555 bin/sld bin/slctl ${DESTDIR}${PREFIX}/sbin
	install -m 0444 lib/SLMON.pm ${SITE}/SLMON.pm
	install -m 0444 lib/SLMON/*.pm ${SITE}/SLMON
	install -m 0444 lib/SLMON/DB/*.pm ${SITE}/SLMON/DB
	install -m 0555 blib/auto/SLMON/Imsg/Imsg.so ${SITE}/${ARCH}/auto/SLMON/Imsg/Imsg.so
	if [ "${WITH_DISH_XS}" = yes ]; then \
		install -d ${SITE}/${ARCH}/auto/SLMON/Dish; \
		install -m 0555 blib/auto/SLMON/Dish/Dish.so \
		    ${SITE}/${ARCH}/auto/SLMON/Dish/Dish.so; \
	fi
	install -m 0444 man/man8/sld.8 man/man8/slctl.8 ${DESTDIR}${PREFIX}/man/man8
	install -m 0444 man/man5/sl.conf.5 ${DESTDIR}${PREFIX}/man/man5
	install -m 0444 etc/sl.conf ${DESTDIR}${PREFIX}/share/examples/slmon/sl.conf
	# The port packages this script with @rcscript.
	if [ "${SKIP_RCD}" != yes ]; then \
		install -d ${DESTDIR}/etc/rc.d; \
		install -m 0555 rc.d/sld ${DESTDIR}/etc/rc.d/sld; \
	fi
