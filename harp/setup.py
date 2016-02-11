#!/usr/bin/python

from setuptools import setup, find_packages

version = open("version").readline().strip().replace("v", "")

setup(
    name = "harp",
    version = version,
    description = "HarpCaller client",
    packages    = find_packages("lib"),
    package_dir = { "": "lib" },
    install_requires = [],
)
