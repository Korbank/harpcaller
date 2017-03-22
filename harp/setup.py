#!/usr/bin/python

from setuptools import setup, find_packages

setup(
    name = "harp",
    version = "0.5.0",
    description = "HarpCaller client",
    packages    = find_packages("lib"),
    package_dir = { "": "lib" },
    install_requires = [],
)
