#!/usr/bin/python
'''
Module loader module
--------------------

Module loader can load Python modules as well as snippets stored in arbitrary
files. The latter enables storing configuration as a Python code.

Note that typically it's a better idea to store configuration in INI, YAML or
JSON files than in Python code, because it's easier to generate and process in
other tools and even languages.

.. autoclass:: ModuleLoader
   :members:

'''
#-----------------------------------------------------------------------------

import imp
import tempfile
import shutil
import os

#-----------------------------------------------------------------------------

class ModuleLoader:
    '''
    Module loader. It can load module from :obj:`sys.path` or a code snippet
    from outside.

    :class:`ModuleLoader` is a context manager.
    '''

    def __init__(self):
        self._tmpdir = tempfile.mkdtemp()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()

    def __del__(self):
        self.close()

    def close(self):
        '''
        Clean up temporary directory. This function is also called on object
        destruction, so there's no need (but no harm, either) to call it
        separately.
        '''
        if self._tmpdir is not None:
            shutil.rmtree(self._tmpdir)
            self._tmpdir = None

    def load(self, name, file = None):
        '''
        :param name: name of the module to load
        :param file: module's file name
        :return: imported module's handle

        Load specified module and return its handle. Module can be loaded from
        outside of :obj:`sys.path` (e.g. from :file:`/etc`) by providing its
        file name. (In such case, no ``*.pyc`` is stored along the original
        file.)

        **NOTE**: Specifying a :obj:`name` under non-existent hierarchy may
        cause a warning to be issued. Better stick to a name that exists
        except for the last component, e.g.
        :obj:`korrpcd.__config__`.
        '''
        if file is None:
            module = __import__(name)
            # `module' now contains top-level module, hence some digging
            # required
            for n in name.split('.')[1:]:
                module = getattr(module, n)
        else:
            if '.' in name:
                # try to load "parent" module, so imp.load_source() won't
                # complain
                try:
                    parent_module = name[0:name.rfind('.')]
                    __import__(parent_module)
                except ImportError:
                    pass # not a problem, but will emit warning

            # we need a file name under tmpdir, so *.pyc file lands there;
            # let's lie a little to the interpreter
            dummy_filename = os.path.join(self._tmpdir, file)
            module = imp.load_source(name, dummy_filename, open(file))

        return module

#-----------------------------------------------------------------------------
# vim:ft=python:foldmethod=marker
