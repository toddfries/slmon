REGRESS_TARGETS = run-unit run-imsg run-dish-pledge run-db-sqlite run-db-pg \
	run-e2e-sqlite run-e2e-pg run-live

PERL = /usr/bin/perl
ROOT = ${.CURDIR:H}
CLEANFILES += ptyfeed

.PHONY: ${REGRESS_TARGETS}

ptyfeed: ptyfeed.c
	cc -g -O2 -Wall -o ptyfeed ptyfeed.c -lutil

run-unit:
	cd ${ROOT} && ${PERL} regress/unit.pl

run-imsg:
	cd ${ROOT} && PERL5LIB=lib:blib ${PERL} regress/imsg.pl

run-dish-pledge:
	cd ${ROOT} && PERL5LIB=lib:blib ${PERL} regress/dishpledge.pl

run-db-sqlite:
	cd ${ROOT} && ${PERL} regress/db.pl sqlite

run-db-pg:
	cd ${ROOT} && ${PERL} regress/db.pl pg

run-e2e-sqlite: ptyfeed
	cd ${ROOT} && PERL5LIB=lib:blib ${PERL} regress/e2e.pl sqlite

run-e2e-pg: ptyfeed
	cd ${ROOT} && PERL5LIB=lib:blib ${PERL} regress/e2e.pl pg

run-live:
	@if nc -z -w 2 192.168.100.1 9200; then \
		cd ${ROOT} && PERL5LIB=lib:blib ${PERL} bin/slmon once \
		    | grep '"status"'; \
	else \
		echo "SKIP live dish: 192.168.100.1:9200 does not answer" >&2; \
	fi

.include <bsd.regress.mk>
