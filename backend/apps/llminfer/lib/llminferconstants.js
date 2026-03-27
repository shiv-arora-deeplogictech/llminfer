/**
 * LLMinfer constants.
 * (C) 2025 TekMonks. All rights reserved.
 */

const path = require("path");

const APPROOT = path.resolve(`${__dirname}/../`);

exports.APPROOT    = APPROOT;
exports.APIDIR     = path.resolve(`${APPROOT}/apis`);
exports.CONFDIR    = path.resolve(`${APPROOT}/conf`);
exports.LIBDIR     = path.resolve(`${APPROOT}/lib`);
exports.PYTHONDIR  = path.resolve(`${APPROOT}/../../../python`);
exports.MODELS_DIR = path.resolve(`${APPROOT}/../../../models`);
