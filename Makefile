# Build the imsg and dish extensions, then the regress suite.

.PHONY: all regress clean

all:
	cd ext/imsg && ${MAKE}
	cd ext/dishbridge && ${MAKE}

regress: all
	cd regress && ${MAKE} regress

clean:
	cd ext/imsg && ${MAKE} clean
	cd ext/dishbridge && ${MAKE} clean
	cd regress && ${MAKE} clean
