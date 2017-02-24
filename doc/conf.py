#-----------------------------------------------------------------------------
#
# Sphinx configuration for HarpCaller project
#
#-----------------------------------------------------------------------------

project = u'HarpCaller RPC system'
copyright = u'2016, Korbank S.A.'

release = '0.4.1'
version = '0.4'

#-----------------------------------------------------------------------------

# minimal Sphinx version
#needs_sphinx = '1.0'

extensions = ['sphinx.ext.autodoc', 'sphinx.ext.todo']

master_doc = 'index'
source_suffix = '.rst'
exclude_trees = ['html', 'man']

#-----------------------------------------------------------------------------
# configuration specific to Python code
#-----------------------------------------------------------------------------

import sys, os
sys.path.insert(0, os.path.abspath('../daemon/lib'))
sys.path.insert(0, os.path.abspath('../harp/lib'))

# ignored prefixes for module index sorting
#modindex_common_prefix = []

# documentation for constructors: docstring from class, constructor, or both
autoclass_content = 'both'

#-----------------------------------------------------------------------------
# HTML output
#-----------------------------------------------------------------------------

import sphinx
def ver(v):
    return [int(i) for i in v.split('.')]

if ver(sphinx.__version__) >= ver('1.3'):
    html_theme = 'classic'
else:
    html_theme = 'default'

pygments_style = 'sphinx'

#html_static_path = ['static']

#-----------------------------------------------------------------------------
# TROFF/man output
#-----------------------------------------------------------------------------

man_pages = [
    ('manpages/client', 'harp', 'HarpCaller Python client',
     [], 3),
    ('manpages/daemon', 'harpd', 'Harp RPC server',
     [], 8),
    ('manpages/dispatcher', 'harpcallerd', 'HarpCaller broker daemon',
     [], 8),
]

#man_show_urls = False

#-----------------------------------------------------------------------------
# vim:ft=python
