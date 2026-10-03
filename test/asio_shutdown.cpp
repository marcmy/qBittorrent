// Regression harness for the patched Boost.Asio Windows IOCP helper.
#include <boost/asio.hpp>
#include <boost/asio/detail/select_reactor.hpp>

#include <chrono>
#include <iostream>
#include <stdexcept>
#include <string_view>
#include <thread>
#include <windows.h>

unsigned long long processCPUTime()
{
    FILETIME created {}, exited {}, kernel {}, user {};
    if (!GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user))
        throw std::runtime_error("GetProcessTimes failed");
    const auto ticks = [](FILETIME time)
    {
        return (static_cast<unsigned long long>(time.dwHighDateTime) << 32) | time.dwLowDateTime;
    };
    return ticks(kernel) + ticks(user);
}

int main(int argc, char **argv)
{
    using namespace std::chrono_literals;
    const std::string_view mode = (argc > 1) ? argv[1] : "normal";
    const auto started = std::chrono::steady_clock::now();
    const auto cpuStarted = processCPUTime();
    {
        boost::asio::io_context context;
        boost::asio::use_service<boost::asio::detail::select_reactor>(context);
        if (mode == "normal")
        {
            using boost::asio::ip::tcp;
            tcp::acceptor acceptor(context, tcp::endpoint(tcp::v4(), 0));
            tcp::socket client(context);
            client.connect(tcp::endpoint(boost::asio::ip::address_v4::loopback(), acceptor.local_endpoint().port()));
            auto server = acceptor.accept();
            char received = 0;
            bool readDone = false;
            bool timerDone = false;
            boost::asio::async_read(server, boost::asio::buffer(&received, 1),
                [&](const boost::system::error_code &error, std::size_t count)
                {
                    readDone = !error && (count == 1) && (received == 'x');
                });
            boost::asio::steady_timer timer(context, 20ms);
            timer.async_wait([&](const boost::system::error_code &error) { timerDone = !error; });
            boost::asio::write(client, boost::asio::buffer("x", 1));
            context.run();
            if (!readDone || !timerDone)
                return 1;
        }
        else
        {
            // Let the reactor enter select before destruction. The fault build
            // suppresses interrupter sends, exercising the timeout fallback.
            std::this_thread::sleep_for((mode == "idle") ? 3s : 200ms);
        }
    }
    std::cout << mode << ": elapsed_ms="
        << std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - started).count()
        << " cpu_ms=" << ((processCPUTime() - cpuStarted) / 10000.0) << '\n';
}
