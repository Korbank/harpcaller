#!/usr/bin/python

from setuptools import setup, find_packages
from glob import glob

setup(
    name = "harpd",
    version = "0.5.0",
    description = "HarpRPC daemon",
    scripts     = glob("bin/*"),
    packages    = find_packages("lib"),
    package_dir = { "": "lib" },
    install_requires = [
        "yaml",
    ],
)
