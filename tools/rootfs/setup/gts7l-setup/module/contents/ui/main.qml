// SPDX-License-Identifier: LGPL-2.1-or-later
//
// gts7l page of KDE's first-boot wizard (plasma-setup), between the time zone
// and Wi-Fi pages. The choices are applied by Gts7lSetup.apply() when the
// wizard finishes (onFinish, called by the gts7l plasma-setup package).

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import org.kde.kirigami as Kirigami

import org.kde.plasmasetup
import org.kde.plasmasetup.components as PlasmaSetupComponents
import org.gts7l.setup

PlasmaSetupComponents.SetupModule {
    id: root

    nextEnabled: !rootSwitch.checked
                 || (rootPasswordField.text.length > 0 && rootPasswordField.text === rootRepeatField.text
                     && !/[:\n]/.test(rootPasswordField.text))

    function onFinish() {
        Gts7lSetup.autoBrightness = brightnessSwitch.checked;
        Gts7lSetup.autoRotate = rotateSwitch.checked;
        Gts7lSetup.autologin = autologinSwitch.checked;
        Gts7lSetup.ssh = sshSwitch.checked;
        Gts7lSetup.windowsSupport = windowsSwitch.checked;
        Gts7lSetup.rootPasswordEnabled = rootSwitch.checked;
        Gts7lSetup.rootPassword = rootSwitch.checked ? rootPasswordField.text : "";
        Gts7lSetup.apply(AccountController.username);
    }

    contentItem: ScrollView {
        id: scroll
        clip: true

        ColumnLayout {
            width: scroll.availableWidth

            ColumnLayout {
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                Layout.maximumWidth: root.cardWidth
                spacing: Kirigami.Units.largeSpacing

                Label {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    text: i18n("All of these can be changed later in System Settings.")
                }

                Kirigami.FormLayout {
                    Layout.fillWidth: true

                    Kirigami.Separator {
                        Kirigami.FormData.label: i18n("Display")
                        Kirigami.FormData.isSection: true
                    }

                    Switch {
                        id: brightnessSwitch
                        Kirigami.FormData.label: i18n("Automatic brightness:")
                        text: i18n("Follow the ambient light sensor")
                        checked: true
                    }

                    Switch {
                        id: rotateSwitch
                        Kirigami.FormData.label: i18n("Auto-rotate:")
                        text: i18n("Rotate the screen with the tablet")
                        checked: true
                    }

                    Kirigami.Separator {
                        Kirigami.FormData.label: i18n("Login")
                        Kirigami.FormData.isSection: true
                    }

                    Switch {
                        id: autologinSwitch
                        Kirigami.FormData.label: i18n("Automatic login:")
                        text: i18n("Start the desktop without asking for the password")
                        checked: false
                    }

                    Switch {
                        id: rootSwitch
                        Kirigami.FormData.label: i18n("Root account:")
                        text: i18n("Set a root password")
                        checked: false
                    }

                    Label {
                        visible: !rootSwitch.checked
                        Layout.maximumWidth: root.cardWidth * 0.6
                        wrapMode: Text.Wrap
                        font: Kirigami.Theme.smallFont
                        text: i18n("Off: root stays locked; your account can use sudo.")
                    }

                    Kirigami.PasswordField {
                        id: rootPasswordField
                        visible: rootSwitch.checked
                        Kirigami.FormData.label: i18n("Root password:")
                    }

                    Kirigami.PasswordField {
                        id: rootRepeatField
                        visible: rootSwitch.checked
                        Kirigami.FormData.label: i18n("Repeat:")
                    }

                    Kirigami.InlineMessage {
                        Layout.fillWidth: true
                        type: Kirigami.MessageType.Error
                        visible: rootSwitch.checked && rootRepeatField.text.length > 0
                                 && rootRepeatField.text !== rootPasswordField.text
                        text: i18n("The passwords do not match.")
                    }

                    Kirigami.Separator {
                        Kirigami.FormData.label: i18n("Extras")
                        Kirigami.FormData.isSection: true
                    }

                    Switch {
                        id: sshSwitch
                        Kirigami.FormData.label: i18n("SSH server:")
                        text: i18n("Allow remote logins over the network")
                        checked: false
                    }

                    Switch {
                        id: windowsSwitch
                        Kirigami.FormData.label: i18n("Windows programs:")
                        text: i18n("Install Wine when the tablet is online (about 300 MB)")
                        checked: false
                    }
                }
            }
        }
    }
}
