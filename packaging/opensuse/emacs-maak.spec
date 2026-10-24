#
# spec file for package emacs-maak
#
# Copyright (c) 2026 SUSE LLC and contributors
#
# All modifications and additions to the file contributed by third parties
# remain the property of their copyright owners, unless otherwise agreed
# upon. The license for this file, and modifications and additions to the
# file, is the same license as for the pristine package itself (unless the
# license for the pristine package is not an Open Source License, in which
# case the license is the MIT License). An "Open Source License" is a
# license that conforms to the Open Source Definition (Version 1.9)
# published by the Open Source Initiative.

# Please submit bugfixes or comments via http://bugs.opensuse.org/
#

Name:           emacs-maak
Version:        0.9.1
Release:        0
Summary:        Maak integration for Emacs
License:        GPL-3.0-or-later
URL:            https://codeberg.org/jjba23/maak.el
Source0:        maak.el-%{version}.tar.gz
BuildRequires:  emacs
Requires:       emacs

%description
Maak.el reads a project's Maak file the way maak does, completes the tasks
it exports together with the arguments they take, and runs them from inside
Emacs.

%prep
%autosetup -n maak.el-%{version}

%build
emacs -Q --batch -f batch-byte-compile maak.el

%install
install -d %{buildroot}%{_datadir}/emacs/site-lisp
install -m 0644 maak.el maak.elc %{buildroot}%{_datadir}/emacs/site-lisp/

%check
emacs -Q --batch -L . -L test -l test/maak-test.el -f ert-run-tests-batch-and-exit

%files
%license COPYING
%doc README.org
%{_datadir}/emacs/site-lisp/maak.el
%{_datadir}/emacs/site-lisp/maak.elc

%changelog
