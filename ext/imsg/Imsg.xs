#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <imsg.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

typedef struct imsgbuf Imsgbuf;

static Imsgbuf *
ib_ptr(SV *self)
{
	SV *rv;

	if (!SvROK(self))
		croak("SLMON::Imsg method called on a non-object");
	rv = SvRV(self);
	/* Perl 5.42 sv_setref_pv stores the pointer with PTR2IV. */
	if (!SvIOK(rv))
		croak("SLMON::Imsg method called on a non-object");
	return INT2PTR(Imsgbuf *, SvIV(rv));
}

MODULE = SLMON::Imsg  PACKAGE = SLMON::Imsg

PROTOTYPES: DISABLE

SV *
new(const char *class, int fd)
CODE:
	Imsgbuf *ib;
	SV *rv;
	ib = (Imsgbuf *)calloc(1, sizeof(*ib));
	if (ib == NULL)
		croak("calloc: %s", strerror(errno));
	if (imsgbuf_init(ib, fd) == -1) {
		free(ib);
		croak("imsgbuf_init: %s", strerror(errno));
	}
	rv = newSV(0);
	sv_setref_pv(rv, class, (void *)ib);
	RETVAL = rv;
OUTPUT:
	RETVAL

void
DESTROY(SV *self)
CODE:
	if (SvROK(self) && SvIOK(SvRV(self))) {
		Imsgbuf *ib = INT2PTR(Imsgbuf *, SvIV(SvRV(self)));
		if (ib != NULL) {
			imsgbuf_clear(ib);
			free(ib);
			SvIV_set(SvRV(self), 0);
		}
	}

void
allow_fdpass(SV *self)
CODE:
	imsgbuf_allow_fdpass(ib_ptr(self));

int
set_maxsize(SV *self, unsigned long max)
CODE:
	RETVAL = imsgbuf_set_maxsize(ib_ptr(self), (uint32_t)max);
OUTPUT:
	RETVAL

int
fd(SV *self)
CODE:
	RETVAL = ib_ptr(self)->fd;
OUTPUT:
	RETVAL

int
compose(SV *self, unsigned long type, SV *data, int passfd)
CODE:
	STRLEN len = 0;
	const char *pv = "";
	Imsgbuf *ib = ib_ptr(self);
	if (SvOK(data))
		pv = SvPVbyte(data, len);
	RETVAL = imsg_compose(ib, (uint32_t)type, 0, 0, passfd,
	    len ? pv : NULL, len);
OUTPUT:
	RETVAL

int
flush(SV *self)
CODE:
	RETVAL = imsgbuf_flush(ib_ptr(self));
OUTPUT:
	RETVAL

int
write_once(SV *self)
CODE:
	RETVAL = imsgbuf_write(ib_ptr(self));
OUTPUT:
	RETVAL

int
read_more(SV *self)
CODE:
	RETVAL = imsgbuf_read(ib_ptr(self));
OUTPUT:
	RETVAL

unsigned long
queuelen(SV *self)
CODE:
	RETVAL = imsgbuf_queuelen(ib_ptr(self));
OUTPUT:
	RETVAL

void
get(SV *self)
PPCODE:
	struct imsg im;
	Imsgbuf *ib = ib_ptr(self);
	int r = imsgbuf_get(ib, &im);
	HV *hv;
	size_t len;
	int passfd;
	SV *payload;
	if (r == 0)
		XSRETURN_UNDEF;
	if (r == -1)
		croak("imsgbuf_get: %s", strerror(errno));
	hv = newHV();
	(void)hv_stores(hv, "type", newSVuv(imsg_get_type(&im)));
	len = imsg_get_len(&im);
	if (len > 0) {
		char *buf = (char *)malloc(len);
		if (buf == NULL) {
			imsg_free(&im);
			croak("malloc: %s", strerror(errno));
		}
		if (imsg_get_data(&im, buf, len) == -1) {
			free(buf);
			imsg_free(&im);
			croak("imsg_get_data failed");
		}
		payload = newSVpvn(buf, len);
		free(buf);
	} else {
		payload = newSVpvn("", 0);
	}
	(void)hv_stores(hv, "data", payload);
	passfd = imsg_get_fd(&im);
	(void)hv_stores(hv, "fd", newSViv(passfd));
	imsg_free(&im);
	XPUSHs(sv_2mortal(newRV_noinc((SV *)hv)));
