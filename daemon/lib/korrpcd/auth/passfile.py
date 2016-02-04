#!/usr/bin/python
'''
``korrpcd.auth.passfile``
-------------------------

Records in database file are lines with username and password separated by
colon character. Passwords are hashed using :manpage:`crypt(3)`, possibly with
a function based on SHA-256 (``$5$...$``) or SHA-512 (``$6$...$``).

Usage (:file:`config.yaml`):

.. code-block:: yaml

    authentication:
      module: korrpcd.auth.passfile
      file: /etc/korrpcd/usersdb

Example users database:

.. code-block:: none

    john:$6$g0a5veBmmlwwrZv1$pg6sSG/ql/aZ...
    jane:$6$fIwvwUFehH3F9jmj$gGSa5r82ytJ3...
    jack:$6$2Hhc3dOiJiIazShS$E73GPmrx9qxM...

New record to users database can be prepared this way::

    import crypt
    import random

    def hash_password(password):
        salt_chars = \\
            "abcdefghijklmnopqrstuvwxyz" \\
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ" \\
            "0123456789./"
        salt = "".join([random.choice(salt_chars) for i in xrange(16)])
        return crypt.crypt(password, "$6$%s$" % (salt,))

    # ...
    print "%s:%s" % (username, hash_password(password))

'''
#-----------------------------------------------------------------------------

from .. import auth

import crypt

#-----------------------------------------------------------------------------

class CryptPassFile(auth.AuthDB):
    def __init__(self, passfile):
        self.passfile = passfile

    def authenticate(self, user, password):
        try:
            with open(self.passfile) as f:
                line = f.readline()
                while line != '':
                    (read_user, read_crypt) = line.strip().split(":", 1)
                    if user == read_user:
                        return (crypt.crypt(password, read_crypt) == read_crypt)
                    line = f.readline()
        except IOError:
            pass # no such file, permission errors and so on
        return False

#-----------------------------------------------------------------------------

def create(config):
    return CryptPassFile(config["file"])

#-----------------------------------------------------------------------------
# vim:ft=python:foldmethod=marker
