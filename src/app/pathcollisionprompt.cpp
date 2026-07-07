/*
 * Bittorrent Client using Qt and libtorrent.
 * Copyright (C) 2026  qBittorrent contributors
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 */

#include <QApplication>
#include <QCoreApplication>
#include <QMessageBox>
#include <QPointer>
#include <QPushButton>
#include <QTimer>

#include "base/bittorrent/session.h"
#include "base/bittorrent/torrent.h"

namespace
{
    QString tr(const char *text)
    {
        return QCoreApplication::translate("PathCollisionPrompt", text);
    }

    void showPathCollisionPrompt(BitTorrent::Torrent *torrent, const QStringList &conflictingTorrents)
    {
        QPointer<BitTorrent::Torrent> guardedTorrent {torrent};
        const QString conflictList = QStringLiteral("• ") + conflictingTorrents.join(QStringLiteral("\n• "));

        QMessageBox messageBox {
            QMessageBox::Warning,
            tr("Shared torrent content detected"),
            tr("The torrent \"%1\" shares one or more content paths with another running torrent.")
                    .arg(torrent->name()),
            QMessageBox::NoButton,
            QApplication::activeWindow()
        };
        messageBox.setDetailedText(tr("Conflicting torrents:\n%1\n\nContent path:\n%2")
                .arg(conflictList, torrent->contentPath().toString()));
        messageBox.setInformativeText(tr(
            "Use existing shared data is intended for cross-seeding. qBittorrent will keep the current paths and download only missing pieces. "
            "If the torrents do not contain identical data, shared files can be modified.\n\n"
            "Create protected copy assigns a [qB-...] path and downloads separately.\n\n"
            "Keep stopped makes no changes."));

        auto *useExistingButton = messageBox.addButton(tr("Use existing shared data"), QMessageBox::AcceptRole);
        auto *protectedCopyButton = messageBox.addButton(tr("Create protected copy"), QMessageBox::ActionRole);
        auto *keepStoppedButton = messageBox.addButton(tr("Keep stopped"), QMessageBox::RejectRole);
        messageBox.setDefaultButton(keepStoppedButton);
        messageBox.setEscapeButton(keepStoppedButton);
        messageBox.exec();

        if (!guardedTorrent)
            return;

        if (messageBox.clickedButton() == useExistingButton)
            guardedTorrent->resolvePathCollision(BitTorrent::Torrent::PathCollisionResolution::UseExistingData);
        else if (messageBox.clickedButton() == protectedCopyButton)
            guardedTorrent->resolvePathCollision(BitTorrent::Torrent::PathCollisionResolution::CreateProtectedCopy);
    }

    void connectTorrent(BitTorrent::Torrent *torrent)
    {
        static constexpr char connectedProperty[] = "qbtPathCollisionPromptConnected";
        if (!torrent || torrent->property(connectedProperty).toBool())
            return;

        torrent->setProperty(connectedProperty, true);
        QObject::connect(torrent, &BitTorrent::Torrent::pathCollisionDetected, qApp,
                [torrent](const QStringList &conflictingTorrents)
        {
            const QPointer<BitTorrent::Torrent> guardedTorrent {torrent};
            QTimer::singleShot(0, qApp, [guardedTorrent, conflictingTorrents]
            {
                if (guardedTorrent)
                    showPathCollisionPrompt(guardedTorrent, conflictingTorrents);
            });
        });
    }

    void initializePathCollisionPrompt()
    {
        QTimer::singleShot(0, qApp, []
        {
            auto *session = BitTorrent::Session::instance();
            QObject::connect(session, &BitTorrent::Session::torrentAdded, qApp,
                    [](BitTorrent::Torrent *torrent) { connectTorrent(torrent); });
            QObject::connect(session, &BitTorrent::Session::torrentsLoaded, qApp,
                    [](const QList<BitTorrent::Torrent *> &torrents)
            {
                for (BitTorrent::Torrent *torrent : torrents)
                    connectTorrent(torrent);
            });
            QObject::connect(session, &BitTorrent::Session::restored, qApp, [session]
            {
                for (BitTorrent::Torrent *torrent : session->torrents())
                    connectTorrent(torrent);
            });

            for (BitTorrent::Torrent *torrent : session->torrents())
                connectTorrent(torrent);
        });
    }

    Q_COREAPP_STARTUP_FUNCTION(initializePathCollisionPrompt)
}
