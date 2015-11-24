#!/usr/bin/make -f

all:
	: nothing

install:
	mkdir -p $(DESTDIR)
	python setup.py install --prefix=/usr --exec-prefix=/usr --install-scripts=/usr/sbin --root=$(DESTDIR)

clean:
	python setup.py clean --all
	rm -rf lib/*.egg-info

# file used by debian/rules to override $(VERSION) variable (in case of
# building from source package instead of from git repository)
.PHONY: version
version:
	git describe --long --dirty --abbrev=10 --tags --match 'v*' > $@
