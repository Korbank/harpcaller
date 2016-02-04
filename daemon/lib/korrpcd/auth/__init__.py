#!/usr/bin/python
'''
Interface for authentication backends
-------------------------------------

.. autoclass:: AuthDB
   :members:

.. autofunction:: create

'''
#-----------------------------------------------------------------------------

class AuthDB(object):
    '''
    Base class for authentication objects. Instance of this class (or rather,
    a subclass of this class) should be returned by :func:`create()`.
    '''
    def authenticate(self, user, password):
        '''
        :return: ``True`` if :obj:`user` + :obj:`password` pair was correct,
            ``False`` otherwise

        Check if the :obj:`password` was valid for specified :obj:`user`.
        '''
        raise NotImplementedError(
            "%s.authenticate(user, password)" % (self.__class__.__name__,)
        )

def create(config):
    '''
    :param config: parameters read from config
    :type config: dict
    :return: authentication database object
    :rtype: :class:`AuthDB`

    Equivalent of this function in an authentication backend module is called
    to create an auth database for future use.
    '''
    raise NotImplementedError("create(config)")

#-----------------------------------------------------------------------------
# vim:ft=python:foldmethod=marker
