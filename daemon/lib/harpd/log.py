#!/usr/bin/python
'''
Structured logging helper
-------------------------

.. autofunction:: message

.. autoclass:: Message

'''
#-----------------------------------------------------------------------------

import collections
import json

#-----------------------------------------------------------------------------

class Message(collections.OrderedDict):
    '''
    Dictionary that remembers the order keys were insterted in and stringifies
    to JSON preserving the keys order.
    '''
    def __str__(self):
        return json.dumps(self)

#-----------------------------------------------------------------------------
# message('log message', (key, value), key = value)

def message(*args, **kwargs):
    '''
    Function to easily create :class:`Message` instances.

    Most of the time, order of the keys is irrelevant, so :obj:`kwargs` is
    stored in :class:`Message` in lexicographic order.

    If some specific order is needed for message readability (it's still logs,
    so humans are still an important audience), pairs ``(key, value)`` can be
    provided in positional arguments.

    The first positional argument can be simply a string, in which case it
    will be the first in :class:`Message` element stored under the key
    ``"message"``.

    Typical usage::

        from harpd.log import message as log

        # ...
        logger.info(log("host is down", hostname = hostname, ...))
    '''
    args = list(args)
    if len(args) > 0 and type(args[0]) != tuple:
        args[0] = ('message', args[0])

    msg = Message(args)
    for k in sorted(kwargs):
        msg[k] = kwargs[k]

    return msg


#-----------------------------------------------------------------------------
# vim:ft=python
