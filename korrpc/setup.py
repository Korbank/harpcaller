#!/usr/bin/python

from setuptools import setup, find_packages

version = open("version").readline().strip().replace("v", "")

setup(
    name = "korrpc",
    version = version,
    description = "KorRPC client",
    packages    = find_packages("lib"),
    package_dir = { "": "lib" },
    install_requires = [],
)
