PREFIX ?= /usr/local
VERSION ?= 0.0.0

greet: src/greet.c
	$(CC) $(CFLAGS) -DVERSION='"$(VERSION)"' -o $@ $<

install: greet
	install -Dm755 greet $(DESTDIR)$(PREFIX)/bin/greet

.PHONY: install
