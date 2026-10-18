#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "dishbridge.h"
#include <stdlib.h>

MODULE = SLMON::Dish  PACKAGE = SLMON::Dish

PROTOTYPES: DISABLE

SV *
call(const char *target, const char *op)
CODE:
	char *out = NULL;
	char *err = NULL;
	int rc = slmon_dish_call(target, op, &out, &err);
	if (rc != 0) {
		const char *em = err ? err : "dish call failed";
		SV *e = sv_2mortal(newSVpv(em, 0));
		free(out);
		free(err);
		croak("%s", SvPV_nolen(e));
	}
	RETVAL = newSVpv(out ? out : "", 0);
	free(out);
	free(err);
OUTPUT:
	RETVAL
