//
//  main.swift
//  ProxyPilotTransparentProxy
//
//  Entry point for the system extension. The system launches the extension
//  binary directly; this hands the process over to Network Extension system-
//  extension mode, after which the framework drives the provider class
//  (`TransparentProxyProvider`) over XPC. The run loop never returns.
//

import Foundation
import NetworkExtension

NEProvider.startSystemExtensionMode()
dispatchMain()
