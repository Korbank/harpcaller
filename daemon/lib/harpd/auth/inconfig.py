#!/usr/bin/python
'''
``harpd.auth.inconfig``
-------------------------

This backend is intended for simplifying deployment. It doesn't use any
database file, since all the users are specified directly in configuration.

Usage (:file:`config.yaml`):

.. code-block:: yaml

    authentication:
      module: harpd.auth.inconfig
      users:
        john: "plain:john's password"
        jane: "plain:jane's password"
        jack: "crypt:$6$g0a5veBmmlwwrZv1$pg6sSG/ql/aZ..."

Usernames are specified as keys, passwords are specified in
``scheme:password`` format, with ``scheme`` being either ``plain`` (plain text
passwords, not recommended) or ``crypt``.

See :mod:`harpd.auth.passfile` for details on how to hash a password with
:manpage:`crypt(3)`.

'''
#-----------------------------------------------------------------------------

from .. import auth

import crypt

#-----------------------------------------------------------------------------

class PlainUserList(auth.AuthDB):
    def __init__(self, users):
        self.users = {}
        for (user, passwd) in users.items():
            if passwd.startswith("plain:"):
                self.users[user] = {
                    "password": passwd[len("plain:"):]
                }
            elif passwd.startswith("crypt:"):
                self.users[user] = {
                    "crypt": passwd[len("crypt:"):]
                }
            # else error

    def authenticate(self, user, password):
        if user not in self.users:
            return False
        if "password" in self.users[user]:
            return (password == self.users[user]["password"])
        if "crypt" in self.users[user]:
            crypt_password = self.users[user]["crypt"]
            return (crypt.crypt(password, crypt_password) == crypt_password)

#-----------------------------------------------------------------------------

def create(config):
    return PlainUserList(config["users"])

#-----------------------------------------------------------------------------
# vim:ft=python:foldmethod=marker
