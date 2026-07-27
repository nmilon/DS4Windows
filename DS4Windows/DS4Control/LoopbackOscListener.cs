/*
DS4Windows
Copyright (C) 2023  Travis Nickles

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

using System;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using SharpOSC;

namespace DS4WinWPF.DS4Control
{
    // Drop-in replacement for SharpOSC's UDPListener that binds 127.0.0.1
    // instead of every interface.
    //
    // The OSC command surface writes synthetic controller input, and
    // DS4Windows maps controller input to keyboard and mouse, so an
    // interface-wide bind hands remote input injection to anything on the
    // LAN. SharpOSC's UDPListener takes only a port and always binds
    // IPAddress.Any, so it cannot be constrained; this listener reuses
    // SharpOSC purely for packet parsing.
    public sealed class LoopbackOscListener : IDisposable
    {
        public int Port { get; }

        private readonly UdpClient client;
        private readonly HandleOscPacket callback;
        private readonly CancellationTokenSource cancelSource = new CancellationTokenSource();
        private readonly Thread receiveThread;
        private volatile bool closed;

        public LoopbackOscListener(int port, HandleOscPacket callback)
        {
            Port = port;
            this.callback = callback;

            client = new UdpClient(new IPEndPoint(IPAddress.Loopback, port));

            receiveThread = new Thread(ReceiveLoop)
            {
                IsBackground = true,
                Name = "LoopbackOscListener",
            };
            receiveThread.Start();
        }

        private void ReceiveLoop()
        {
            IPEndPoint sender = new IPEndPoint(IPAddress.Loopback, 0);

            while (!closed && !cancelSource.IsCancellationRequested)
            {
                byte[] data;
                try
                {
                    data = client.Receive(ref sender);
                }
                catch (SocketException)
                {
                    continue;
                }
                catch (ObjectDisposedException)
                {
                    return;
                }

                // A malformed datagram must not take the listener down.
                try
                {
                    OscPacket packet = OscPacket.GetPacket(data);
                    if (packet != null)
                    {
                        callback?.Invoke(packet);
                    }
                }
                catch (Exception)
                {
                }
            }
        }

        public void Close()
        {
            if (closed) return;

            closed = true;
            cancelSource.Cancel();

            try
            {
                client.Close();
            }
            catch (Exception)
            {
            }
        }

        public void Dispose()
        {
            Close();
            cancelSource.Dispose();
        }
    }
}
