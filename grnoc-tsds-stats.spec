Name: grnoc-tsds-stats
Version: 1.0.0
Release: 1%{?dist}
Summary: TSDS Stats Scripts	

Group: Measurement
License: GRNOC
URL: http://globalnoc.iu.edu
Source0: %{name}-%{version}.tar.gz
BuildRoot: %{_tmppath}/%{name}-%{version}-%{release}-root
BuildArch: noarch
#BuildRequires:	
Requires: perl
Requires: perl-JSON	
Requires: perl-MongoDB
Requires: perl-GRNOC-Log
Requires: perl-GRNOC-WebService-Client
Requires: perl-GRNOC-Monitoring-Service-Status

%description
GRNOC TSDS Status

%prep
%setup -q -n grnoc-tsds-stats-%{version}

%pre
# create a user and group, if one doesn't exist, to run the meta-manager 
/usr/bin/getent passwd tsds || /usr/sbin/useradd -r -U -s /sbin/nologin tsds

%install
rm -rf $RPM_BUILD_ROOT
#make pure_install

# Creates folders
%{__install} -d -p %{buildroot}/etc/grnoc/tsds-stats/
%{__install} -d -p %{buildroot}/usr/bin/
%{__install} -d -p %{buildroot}/etc/cron.d/
%{__install} -d -p %{buildroot}/var/lib/grnoc/tsds-stats/

#Copy files
%{__install} conf/config.xml %{buildroot}/etc/grnoc/tsds-stats/config.xml
%{__install} conf/logging.conf %{buildroot}/etc/grnoc/tsds-stats/logging.conf
%{__install} conf/tsds-stats.cron %{buildroot}/etc/cron.d/tsds-stats.cron
%{__install} bin/tsds-stats.pl %{buildroot}/usr/bin/tsds-stats.pl

#find %{buildroot} -name .packlist -exec %{__rm} {} \;
#%{_fixperms} $RPM_BUILD_ROOT/*

%clean
rm -rf $RPM_BUILD_ROOT

#Setting permissions
%files
%defattr(644, root, root, 755)
%config(noreplace) /etc/grnoc/tsds-stats/config.xml
%config(noreplace) /etc/grnoc/tsds-stats/logging.conf
%config(noreplace) /etc/cron.d/tsds-stats.cron

%defattr(-, root, root, 755)
%dir /var/lib/grnoc/tsds-stats/ 

%defattr(754, tsds, tsds, -)
/usr/bin/tsds-stats.pl
