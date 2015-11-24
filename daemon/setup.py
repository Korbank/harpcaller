#!/usr/bin/python

from setuptools import setup, find_packages
from glob import glob

version = open("version").readline().strip().replace("v", "")

setup(
    name = "korrpcd",
    version = version,
    description = "KorRPC daemon",
    scripts     = glob("bin/*"),
    packages    = find_packages("lib"),
    package_dir = { "": "lib" },
    install_requires = [
        "yaml",
    ],
)
