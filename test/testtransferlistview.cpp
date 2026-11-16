/*
 * Bittorrent Client using Qt and libtorrent.
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 *
 * In addition, as a special exception, the copyright holders give permission to
 * link this program with the OpenSSL project's "OpenSSL" library (or with
 * modified versions of it that use the same license as the "OpenSSL" library),
 * and distribute the linked executables. You must obey the GNU General Public
 * License in all respects for all of the code used other than "OpenSSL".  If you
 * modify file(s), you may extend this exception to your version of the file(s),
 * but you are not obligated to do so. If you do not wish to do so, delete this
 * exception statement from your version.
 */

#include <QCoreApplication>
#include <QMouseEvent>
#include <QScrollBar>
#include <QStandardItemModel>
#include <QTest>

#include "gui/transferlistview.h"

class TestTransferListView final : public QObject
{
    Q_OBJECT
    Q_DISABLE_COPY_MOVE(TestTransferListView)

public:
    TestTransferListView() = default;

private slots:
    void stopScrollingOnRelease_data() const
    {
        QTest::addColumn<bool>("upwards");
        QTest::addColumn<bool>("outside");

        QTest::newRow("bottom-inside") << false << false;
        QTest::newRow("top-inside") << true << false;
        QTest::newRow("bottom-outside") << false << true;
        QTest::newRow("top-outside") << true << true;
    }

    void stopScrollingOnRelease() const
    {
        QFETCH(bool, upwards);
        QFETCH(bool, outside);

        QStandardItemModel model {2000, 1};
        for (int row = 0; row < model.rowCount(); ++row)
            model.setData(model.index(row, 0), QString::number(row));

        TransferListView view;
        view.setModel(&model);
        view.setSelectionMode(QAbstractItemView::ExtendedSelection);
        view.setSelectionBehavior(QAbstractItemView::SelectRows);
        view.setRootIsDecorated(false);
        view.setUniformRowHeights(true);
        view.setDragDropMode(QAbstractItemView::DropOnly);
        view.setAutoScroll(true);
        view.resize(400, 280);
        view.show();
        QCoreApplication::processEvents();

        QScrollBar *const scrollBar = view.verticalScrollBar();
        QVERIFY(scrollBar->maximum() > 300);
        scrollBar->setValue(300);

        // Repeat to verify that ending one drag does not disable the next one.
        for (int gesture = 0; gesture < 2; ++gesture)
        {
            QWidget *const viewport = view.viewport();
            const QPoint edge {50, upwards ? 1 : (viewport->height() - 2)};
            const QModelIndex index = view.indexAt(edge);
            QVERIFY(index.isValid());
            const QPoint press = view.visualRect(index).intersected(viewport->rect()).center();
            QTest::mousePress(viewport, Qt::LeftButton, Qt::NoModifier, press);
            const int beforeDrag = scrollBar->value();

            QMouseEvent move {QEvent::MouseMove, edge, viewport->mapToGlobal(edge)
                , Qt::NoButton, Qt::LeftButton, Qt::NoModifier};
            QCoreApplication::sendEvent(viewport, &move);
            QTRY_VERIFY_WITH_TIMEOUT(scrollBar->value() != beforeDrag, 1500);

            const QPoint release = outside
                    ? QPoint(edge.x(), upwards ? -30 : (viewport->height() + 30)) : edge;
            QTest::mouseRelease(viewport, Qt::LeftButton, Qt::NoModifier, release);
            QCoreApplication::processEvents();
            const int afterRelease = scrollBar->value();
            const QModelIndexList selection = view.selectionModel()->selectedRows();
            QVERIFY(!selection.isEmpty());

            // ScrollPerItem uses a 150 ms timer. Allow several timer periods.
            QTest::qWait(500);
            QCOMPARE(scrollBar->value(), afterRelease);
            QCOMPARE(view.selectionModel()->selectedRows(), selection);
            QVERIFY(view.hasAutoScroll());
        }
    }
};

QTEST_MAIN(TestTransferListView)
#include "testtransferlistview.moc"
