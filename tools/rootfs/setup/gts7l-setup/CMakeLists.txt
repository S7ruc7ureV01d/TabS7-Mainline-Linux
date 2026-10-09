# gts7l-setup: the Galaxy Tab S7 page for KDE's first-boot wizard (plasma-setup)
# plus the root helper that applies its choices when the wizard finishes.
cmake_minimum_required(VERSION 3.20)
project(gts7l-setup LANGUAGES CXX)

set(QT_MIN_VERSION 6.8.0)
set(KF6_MIN_VERSION 6.10.0)

find_package(ECM ${KF6_MIN_VERSION} REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH})

include(KDEInstallDirs)
include(KDECMakeSettings)
include(KDECompilerSettings NO_POLICY_SCOPE)
include(ECMQmlModule)

find_package(Qt6 ${QT_MIN_VERSION} REQUIRED COMPONENTS Core Qml)
find_package(KF6 ${KF6_MIN_VERSION} REQUIRED COMPONENTS Auth Package)

# QML backend: org.gts7l.setup (Gts7lSetup singleton)
ecm_add_qml_module(gts7lsetup_backend
    URI "org.gts7l.setup"
    GENERATE_PLUGIN_SOURCE
    SOURCES src/gts7lsetup.cpp src/gts7lsetup.h
)
target_include_directories(gts7lsetup_backend PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/src)
target_link_libraries(gts7lsetup_backend PRIVATE Qt::Core Qt::Qml KF6::AuthCore)
ecm_finalize_qml_module(gts7lsetup_backend)

# Root helper (KAuth helper id org.gts7l.setup, action org.gts7l.setup.apply)
add_executable(gts7l-setup-helper src/helper/gts7lsetuphelper.cpp src/helper/gts7lsetuphelper.h)
target_link_libraries(gts7l-setup-helper Qt::Core KF6::AuthCore)
kauth_install_actions(org.gts7l.setup src/helper/org.gts7l.setup.actions)
install(TARGETS gts7l-setup-helper DESTINATION ${KAUTH_HELPER_INSTALL_DIR})
kauth_install_helper_files(gts7l-setup-helper org.gts7l.setup root)

# The wizard page (KPackage of type KDE/PlasmaSetup)
kpackage_install_package(module org.gts7l.plasmasetup.tablet packages plasma)

install(FILES files/gts7l-setup.rules DESTINATION ${KDE_INSTALL_DATADIR}/polkit-1/rules.d)
install(FILES files/gts7l-install-windows-support.service DESTINATION ${KDE_INSTALL_SYSTEMDUNITDIR}/system)
install(PROGRAMS files/install-hangover.sh files/notify-users DESTINATION ${KDE_INSTALL_LIBDIR}/gts7l-setup)
install(FILES files/gts7l-plasma-setup.tmpfiles DESTINATION ${KDE_INSTALL_LIBDIR}/tmpfiles.d RENAME gts7l-plasma-setup.conf)
