/*
 * Copyright (c) 2013-2026 Devin Teske <dteske@FreeBSD.org>
 * Copyright (c) 2021-2026 Faraz Vahedi <kfv@FreeBSD.org>
 *
 * SPDX-License-Identifier: BSD-2-Clause
 */

/*
 * File text for the ucl target: read, parse, replace, and the flat
 * tree a write is checked against.
 */


#include <sys/stat.h>

#include <ctype.h>

#include <ucl.h>

#include "sysconf_priv.h"
#include "sysconf_ucl.h"

/* Read all of `path' (missing is empty). Returns malloc'd text. */
char *
slurp(const char *path, size_t *lenp)
{
	struct stat sb;
	char *text;
	size_t got;
	ssize_t r;
	int fd;

	*lenp = 0;
	if ((fd = open(path, O_RDONLY)) < 0) {
		if (errno != ENOENT)
			err(EXIT_FAILURE, "%s", path);
		if ((text = strdup("")) == NULL)
			err(EXIT_FAILURE, NULL);
		return (text);
	}
	if (fstat(fd, &sb) != 0)
		err(EXIT_FAILURE, "%s", path);
	if ((text = malloc((size_t)sb.st_size + 1)) == NULL)
		err(EXIT_FAILURE, NULL);
	for (got = 0; got < (size_t)sb.st_size; got += (size_t)r) {
		r = read(fd, text + got, (size_t)sb.st_size - got);
		if (r < 0)
			err(EXIT_FAILURE, "%s", path);
		if (r == 0)
			break;
	}
	close(fd);
	text[got] = '\0';
	*lenp = got;
	return (text);
}

/* Parse `text'; an empty text is an empty object. Fatal on error. */
ucl_object_t *
ucl_parse_text(const char *path, const char *text, size_t len,
    const char **errp)
{
	struct ucl_parser *parser;
	ucl_object_t *top = NULL;
	char *ready;
	size_t rlen;

	if (errp != NULL)
		*errp = NULL;
	ready = ucl_text_ready(text, len, &rlen);
	if ((parser = ucl_parser_new(UCL_PARSE_FLAGS)) == NULL)
		err(EXIT_FAILURE, NULL);
	if (rlen > 0) {
		if (!ucl_parser_add_string(parser, ready, rlen)) {
			if (errp == NULL)
				errx(EXIT_FAILURE, "%s: %s", path,
				    ucl_parser_get_error(parser));
			*errp = strdup(ucl_parser_get_error(parser));
			ucl_parser_free(parser);
			free(ready);
			return (NULL);
		}
		top = ucl_parser_get_object(parser);
	}
	free(ready);
	ucl_parser_free(parser);
	if (top == NULL && (top = ucl_object_typed_new(UCL_OBJECT)) == NULL)
		err(EXIT_FAILURE, NULL);
	return (top);
}

/*
 * Replace `path' atomically with `text', keeping the mode of an
 * existing file.
 */
void
ucl_replace_file(const char *path, const char *text, size_t len)
{
	struct stat sb;
	mode_t mode;
	mode_t mask;
	size_t off;
	ssize_t w;
	int fd;
	char tmp[PATH_MAX];

	if (snprintf(tmp, sizeof(tmp), "%s.XXXXXX", path) >=
	    (int)sizeof(tmp))
		errx(EXIT_FAILURE, "%s: %s", path, strerror(ENAMETOOLONG));
	if ((fd = mkstemp(tmp)) < 0)
		err(EXIT_FAILURE, "%s", tmp);
	if (stat(path, &sb) == 0)
		mode = sb.st_mode & 07777;
	else {
		mask = umask(0);
		umask(mask);
		mode = 0666 & ~mask;
	}
	(void)fchmod(fd, mode);
	for (off = 0; off < len; off += (size_t)w) {
		if ((w = write(fd, text + off, len - off)) < 0) {
			unlink(tmp);
			err(EXIT_FAILURE, "%s", tmp);
		}
	}
	if (fsync(fd) != 0 || close(fd) != 0 || rename(tmp, path) != 0) {
		unlink(tmp);
		err(EXIT_FAILURE, "%s", path);
	}
}

/*
 * A flattened tree: dotted path -> rendering, last definition wins.
 * Used to prove an edit did exactly what was asked.
 */
void
flat_set(struct flat *f, const char *name, const char *value)
{
	char **tmp;
	size_t i;

	for (i = 0; i < f->n; i++) {
		if (strcmp(f->names[i], name) == 0) {
			free(f->values[i]);
			if ((f->values[i] = strdup(value)) == NULL)
				err(EXIT_FAILURE, NULL);
			return;
		}
	}
	if ((tmp = realloc(f->names, (f->n + 1) * sizeof(*tmp))) == NULL)
		err(EXIT_FAILURE, NULL);
	f->names = tmp;
	if ((tmp = realloc(f->values, (f->n + 1) * sizeof(*tmp))) == NULL)
		err(EXIT_FAILURE, NULL);
	f->values = tmp;
	if ((f->names[f->n] = strdup(name)) == NULL ||
	    (f->values[f->n] = strdup(value)) == NULL)
		err(EXIT_FAILURE, NULL);
	f->n++;
}

/* Drop `name' and everything beneath `name.' */
void
flat_remove(struct flat *f, const char *name)
{
	size_t i;
	size_t j;
	size_t len = strlen(name);

	for (i = j = 0; i < f->n; i++) {
		if (strcmp(f->names[i], name) == 0 ||
		    (strncmp(f->names[i], name, len) == 0 &&
		    f->names[i][len] == '.')) {
			free(f->names[i]);
			free(f->values[i]);
			continue;
		}
		f->names[j] = f->names[i];
		f->values[j] = f->values[i];
		j++;
	}
	f->n = j;
}

int
flat_cb(const char *name, const char *value, ucl_type_t type __unused,
    void *arg)
{

	flat_set(arg, name, value);
	return (0);
}

void
flat_free(struct flat *f)
{
	size_t i;

	for (i = 0; i < f->n; i++) {
		free(f->names[i]);
		free(f->values[i]);
	}
	free(f->names);
	free(f->values);
}

/* True when the two flattenings agree exactly */
int
flat_equal(const struct flat *a, const struct flat *b)
{
	size_t i;
	size_t j;

	if (a->n != b->n)
		return (0);
	for (i = 0; i < a->n; i++) {
		for (j = 0; j < b->n; j++)
			if (strcmp(a->names[i], b->names[j]) == 0)
				break;
		if (j == b->n || strcmp(a->values[i], b->values[j]) != 0)
			return (0);
	}
	return (1);
}

/*
 * The file that receives a write request: the authoritative file when it
 * is writable, otherwise the target's default (pkg sends a repository key
 * to the local repos file and a global key to pkg.conf).
 */
size_t
ucl_write_target(const struct request *req)
{

	if (req->srcidx < 0 || req->srcidx == defaults_idx ||
	    (conf_ro != NULL && conf_ro[req->srcidx])) {
		if (pkg_target && strchr(req->ucl_base != NULL ?
		    req->ucl_base : req->name, '.') != NULL)
			return (pkg_repos_idx);
		return (write_idx);
	}
	return ((size_t)req->srcidx);
}

/*
 * Replace the parse `top' of a file being edited with that of its
 * current text, so later requests in the same run see earlier edits.
 * Text libucl rejects is fatal here, before anything is written.
 */
ucl_object_t *
ucl_reparse(ucl_object_t *top, const char *path, const char *text,
    size_t len)
{
	ucl_object_t *fresh;
	const char *perr = NULL;

	ucl_object_unref(top);
	if ((fresh = ucl_parse_text(path, text, len, &perr)) == NULL)
		errx(EXIT_FAILURE,
		    "%s: edit would not parse (%s); file left unchanged",
		    path, perr != NULL ? perr : "unknown error");
	return (fresh);
}

