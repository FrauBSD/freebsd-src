/*
 * Copyright (c) 2013-2026 Devin Teske <dteske@FreeBSD.org>
 * Copyright (c) 2021-2026 Faraz Vahedi <kfv@FreeBSD.org>
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * How a new UCL statement is spelled: the file's separator, terminator,
 * quoting, boolean family, and indentation.
 */


#include <ctype.h>

#include <ucl.h>

#include "sysconf_priv.h"
#include "sysconf_ucl.h"

/* Detect the indentation unit used in `s' (first indented line) */
void
detect_indent(const char *s, size_t n, char *out, size_t outsize)
{
	size_t i;
	size_t j;

	for (i = 0; i < n; i = j + 1) {
		for (j = i; j < n && s[j] != '\n'; j++)
			continue;
		if (j > i && (s[i] == ' ' || s[i] == '\t') &&
		    !blank_span(s, i, j)) {
			size_t k = i;

			while (k < j && (s[k] == ' ' || s[k] == '\t'))
				k++;
			if (k - i < outsize) {
				memcpy(out, s + i, k - i);
				out[k - i] = '\0';
				return;
			}
		}
		if (j >= n)
			break;
	}
	strlcpy(out, "  ", outsize);
}

/*
 * Derive the style for new statements from `s' (the file being edited,
 * or a style source when that file is empty): the separator and
 * terminator of the first scalar statement, the separator before `{'
 * of the first object statement, and the indentation unit.
 */
void
detect_style(const char *s, size_t n, struct ustyle *sty)
{
	struct ustmt m;
	struct ustmt st;
	struct uobj in;
	size_t i;
	size_t j;
	int have_scalar = 0;
	int have_obj = 0;

	sty->sep = ':';
	sty->term = 0;
	sty->obj_sep = ':';
	sty->last_bare = 0;
	sty->quote_keys = 0;
	detect_indent(s, n, sty->indent, sizeof(sty->indent));
	i = skip_ws(s, n, 0, 1, 0);
	if (i < n && s[i] == '{')
		i++;	/* JSON-style outer object */
	while (!(have_scalar && have_obj)) {
		j = skip_ws(s, n, i, 1, 1);
		if (j >= n || s[j] == '}' || parse_stmt(s, n, j, &st) != 0 ||
		    st.end <= j)
			break;
		if (!have_scalar && !have_obj)
			sty->quote_keys = (s[st.start] == '"');
		if (st.is_obj) {
			if (!have_obj) {
				sty->obj_sep = st.sep;
				if (st.term != 0)
					sty->term = st.term;
				have_obj = 1;
			}
			/*
			 * Scalars inside the first object set the style,
			 * including whether the last member goes bare
			 * (`a: 1,\n  b: 2\n}').
			 */
			if (!have_scalar &&
			    enum_object(s, n, st.obj_open + 1, "", &m,
			    &in) >= 0 && in.has_scalar) {
				sty->sep = in.scalar.sep;
				if (in.scalar.term != 0 || sty->term == 0)
					sty->term = in.scalar.term;
				sty->last_bare = (in.nstmts > 1 &&
				    in.scalar.term != 0 && in.last.term == 0);
				have_scalar = 1;
			}
		} else if (!have_scalar && !st.is_arr) {
			sty->sep = st.sep;
			if (st.term != 0 || sty->term == 0)
				sty->term = st.term;
			have_scalar = 1;
		}
		i = st.end;
	}
}

/* True when `v' can stand bare as a string value */
static int
bare_safe(const char *v)
{
	const char *p;

	if (*v == '\0')
		return (0);
	for (p = v; *p != '\0'; p++) {
		if (!(isalnum((unsigned char)*p) || *p == '_' || *p == '-' ||
		    *p == '.' || *p == '+' || *p == '/' || *p == '@' ||
		    *p == '%' || *p == ':'))
			return (0);
	}
	/* Would parse as something other than a string */
	if (strcasecmp(v, "yes") == 0 || strcasecmp(v, "no") == 0 ||
	    strcasecmp(v, "true") == 0 || strcasecmp(v, "false") == 0 ||
	    strcasecmp(v, "on") == 0 || strcasecmp(v, "off") == 0 ||
	    strcasecmp(v, "null") == 0 || isdigit((unsigned char)*v))
		return (0);
	return (1);
}

/*
 * True when `k' can stand bare as a libucl key: it must begin with a
 * letter, a digit, `/' or `_', and continue with those or `-' or `.'.
 * `*', `**', `[1m' and the like must be quoted or the library refuses
 * the file; uclcmd(1) may leave `*' bare, which we quote for a parse
 * and write quoted ourselves.
 */
static int
key_bare_safe(const char *k)
{
	const unsigned char *p;

	if (*k == '\0')
		return (0);
	p = (const unsigned char *)k;
	if (!(isalnum(*p) || *p == '/' || *p == '_' || *p >= 0x80))
		return (0);
	for (p++; *p != '\0'; p++) {
		if (!(isalnum(*p) || *p == '_' || *p == '-' || *p == '.' ||
		    *p == '/' || *p >= 0x80))
			return (0);
	}
	return (1);
}

int
key_bare_safe_len(const char *k, size_t n)
{
	char *tmp;
	int r;

	if ((tmp = strndup(k, n)) == NULL)
		err(EXIT_FAILURE, NULL);
	r = key_bare_safe(tmp);
	free(tmp);
	return (r);
}

char *
quote_value(const char *v)
{
	char *out;
	char *o;
	const char *p;

	if ((out = malloc(strlen(v) * 2 + 3)) == NULL)
		err(EXIT_FAILURE, NULL);
	o = out;
	*o++ = '"';
	for (p = v; *p != '\0'; p++) {
		switch (*p) {
		case '"':
		case '\\':
			*o++ = '\\';
			*o++ = *p;
			break;
		case '\n':
			*o++ = '\\';
			*o++ = 'n';
			break;
		case '\t':
			*o++ = '\\';
			*o++ = 't';
			break;
		default:
			*o++ = *p;
		}
	}
	*o++ = '"';
	*o = '\0';
	return (out);
}

/*
 * True when the old value, "quoted" in the text, could have stood bare:
 * its author chose the quotes, and a new value keeps them. Quotes that
 * only the old content called for (a space, say) do not bind the new.
 */
int
quoted_by_choice(const char *oldtext, size_t oldlen)
{
	char *inner;
	int r;

	if (oldlen < 2 || oldtext[0] != '"')
		return (1);
	if ((inner = strndup(oldtext + 1, oldlen - 2)) == NULL)
		err(EXIT_FAILURE, NULL);
	r = bare_safe(inner);
	free(inner);
	return (r);
}

/*
 * The text to write for `val' (parsed from `raw', the value as typed):
 * strings bare when safe and not previously quoted, otherwise quoted;
 * booleans in the spelling family the old text used (`yes'/`no',
 * `on'/`off', `true'/`false'); everything else as typed.
 */
char *
render_value(const ucl_object_t *val, const char *raw, const char *oldtext,
    size_t oldlen, int oldquoted)
{
	const char *sv;
	char *out;
	int b;

	switch (ucl_object_type(val)) {
	case UCL_STRING:
		sv = ucl_object_tostring(val);
		if (!oldquoted && bare_safe(sv))
			out = strdup(sv);
		else
			out = quote_value(sv);
		break;
	case UCL_BOOLEAN:
		b = ucl_object_toboolean(val);
		if (oldlen == 3 && strncasecmp(oldtext, "yes", 3) == 0)
			out = strdup(b ? "yes" : "no");
		else if (oldlen == 2 && strncasecmp(oldtext, "no", 2) == 0)
			out = strdup(b ? "yes" : "no");
		else if (oldlen == 2 && strncasecmp(oldtext, "on", 2) == 0)
			out = strdup(b ? "on" : "off");
		else if (oldlen == 3 && strncasecmp(oldtext, "off", 3) == 0)
			out = strdup(b ? "on" : "off");
		else if (oldlen == 0)
			out = strdup(raw);
		else
			out = strdup(b ? "true" : "false");
		break;
	default:
		out = strdup(raw);
		break;
	}
	if (out == NULL)
		err(EXIT_FAILURE, NULL);
	return (out);
}

void
ubuf_add(struct ubuf *b, const char *s, size_t n)
{
	char *tmp;

	if (b->len + n + 1 > b->cap) {
		b->cap = (b->len + n + 1) * 2;
		if ((tmp = realloc(b->p, b->cap)) == NULL)
			err(EXIT_FAILURE, NULL);
		b->p = tmp;
	}
	memcpy(b->p + b->len, s, n);
	b->len += n;
	b->p[b->len] = '\0';
}

void
ubuf_str(struct ubuf *b, const char *s)
{

	ubuf_add(b, s, strlen(s));
}

/* Splice: text[0,at) + ins + text[from,n) */
char *
splice(const char *s, size_t n, size_t at, size_t from, const char *ins)
{
	struct ubuf b = { NULL, 0, 0 };

	ubuf_add(&b, s, at);
	ubuf_str(&b, ins);
	ubuf_add(&b, s + from, n - from);
	return (b.p);
}

/*
 * Insert `term' (when nonzero) right after the statement or element
 * ending at `at', and `ins' after it; when only a comment follows on
 * that line, `ins' goes at the end of the line instead so the comment
 * stays with what it annotates.
 */
char *
splice_after(const char *s, size_t n, size_t at, char term, const char *ins)
{
	struct ubuf b = { NULL, 0, 0 };
	char *out;
	char *tmp;
	size_t nl;

	for (nl = at; nl < n && s[nl] != '\n'; nl++)
		continue;
	if (blank_span(s, at, nl) || !tail_span(s, n, at, nl)) {
		if (term != 0)
			ubuf_add(&b, &term, 1);
		ubuf_str(&b, ins);
		out = splice(s, n, at, at, b.p);
		free(b.p);
		return (out);
	}
	out = splice(s, n, nl, nl, ins);
	if (term != 0) {
		ubuf_add(&b, &term, 1);
		tmp = splice(out, strlen(out), at, at, b.p);
		free(out);
		free(b.p);
		out = tmp;
	}
	return (out);
}

/* Separator text for a scalar statement in style `sep' */
static const char *
sep_text(char sep)
{

	return (sep == ':' ? ": " : sep == '=' ? " = " : " ");
}

/*
 * Build `key<sep>value<term>' with nested objects for the remaining
 * path components. Each line starts with `prefix' (the siblings'
 * indentation) plus `depth' indentation units; with `oneline', the
 * statement is laid out on a single line instead.
 */
void
emit_new(struct ubuf *b, char **comps, int ncomps, const char *vtext,
    const struct ustyle *sty, const char *prefix, size_t prefix_len,
    int depth, int oneline)
{
	char *q;
	int d;

	if (!oneline) {
		ubuf_add(b, prefix, prefix_len);
		for (d = 0; d < depth; d++)
			ubuf_str(b, sty->indent);
	}
	if (sty->quote_keys || !key_bare_safe(comps[0])) {
		q = quote_value(comps[0]);
		ubuf_str(b, q);
		free(q);
	} else
		ubuf_str(b, comps[0]);
	if (ncomps == 1) {
		ubuf_str(b, sep_text(sty->sep));
		ubuf_str(b, vtext);
		/* The leaf is the last member of whatever holds it */
		if (sty->term != 0 && !(sty->last_bare && depth > 0))
			ubuf_add(b, &sty->term, 1);
		return;
	}
	ubuf_str(b, sty->obj_sep == ':' ? ": {" :
	    sty->obj_sep == '=' ? " = {" : " {");
	ubuf_str(b, oneline ? " " : "\n");
	emit_new(b, comps + 1, ncomps - 1, vtext, sty, prefix, prefix_len,
	    depth + 1, oneline);
	if (oneline)
		ubuf_str(b, " }");
	else {
		ubuf_str(b, "\n");
		ubuf_add(b, prefix, prefix_len);
		for (d = 0; d < depth; d++)
			ubuf_str(b, sty->indent);
		ubuf_str(b, "}");
	}
}

