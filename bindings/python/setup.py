#!/usr/bin/env python
import os
import sys

try:
    from setuptools import setup, Extension
except ImportError:
    sys.exit('The setup requires setuptools.')

TOP_SRCDIR = os.environ.get('ABS_TOP_SRCDIR', '../..')
TOP_BUILDDIR = os.environ.get('ABS_TOP_BUILDDIR', '../..')

# package version
package_version = '0.1.10'


def main():
    # rrdtool is built as part of the /opt/rrdtool bundle, where the extension
    # must locate librrd at runtime through an embedded RPATH. The autotools
    # build passes the install libdir via the RRDTOOL_RPATH environment
    # variable. When this package is built by other means (a plain
    # `pip install`), the variable is simply unset and no RPATH is embedded.
    ext_kwargs = dict(
        sources=['rrdtoolmodule.c'],
        library_dirs=[os.path.join(TOP_BUILDDIR, 'src', '.libs')],
        include_dirs=[os.path.join(TOP_BUILDDIR, 'src'),
                      os.path.join(TOP_SRCDIR, 'src')],
        libraries=['rrd'],
    )
    rpath = os.environ.get('RRDTOOL_RPATH', '')
    if rpath:
        ext_kwargs['runtime_library_dirs'] = [rpath]

    module = Extension('rrdtool', **ext_kwargs)

    kwargs = dict(
        name='rrdtool',
        version=package_version,
        description='Python bindings for rrdtool',
        keywords=['rrdtool'],
        author='Christian Kroeger, Hye-Shik Chang',
        author_email='commx@commx.ws',
        license='LGPL',
        url='https://github.com/commx/python-rrdtool',
        classifiers=['License :: OSI Approved',
                     'Operating System :: POSIX',
                     'Operating System :: Unix',
                     'Operating System :: MacOS',
                     'Programming Language :: C',
                     'Programming Language :: Python',
                     'Programming Language :: Python :: 2.7',
                     'Programming Language :: Python :: 3.3',
                     'Programming Language :: Python :: 3.4',
                     'Programming Language :: Python :: 3.5',
                     'Programming Language :: Python :: 3.10',
        ],
        ext_modules=[module],
        test_suite='tests'
    )

    setup(**kwargs)


if __name__ == '__main__':
    main()
