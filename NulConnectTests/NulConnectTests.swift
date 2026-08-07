//
//  NulConnectTests.swift
//  NulConnectTests
//
//  Created by 孙天阳 on 2026/7/2.
//

import Foundation
import Testing
@testable import NulConnect

struct NulConnectTests {
    @Test func profileStoreRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try ProfileStore(baseDirectory: root)

        var profile = NulConnectProfile.default
        profile.serverHost = "vpn.example.com"
        profile.serverPort = 8443
        profile.loginDomain = "hit.example.com"
        profile.routeMode = .tun
        profile.useSystemProxy = false

        try store.save(profile)
        let loaded = try store.load()

        #expect(loaded == profile)
    }

    @Test func resourceSnapshotRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = try ResourceSnapshotStore(baseDirectory: root)
        let snapshot = ATRResourceSnapshot(
            resourceBytes: Data([0xde, 0xad, 0xbe, 0xef]),
            dnsServer: "8.8.8.8",
            majorNodeGroup: "cn",
            ipResources: [
                ATRIPResource(ipMin: "10.0.0.1", ipMax: "10.0.0.10", portMin: 80, portMax: 443, protocolName: "tcp", appID: "app", nodeGroupID: "group")
            ],
            domainResources: [],
            dnsResources: [],
            nodeGroups: [],
            excludedIPs: ["127.0.0.1"]
        )

        try store.save(snapshot)
        let loadedSnapshot = try store.load()
        let loaded = try #require(loadedSnapshot)

        #expect(loaded.resourceBytes == snapshot.resourceBytes)
        #expect(loaded.dnsServer == snapshot.dnsServer)
        #expect(loaded.majorNodeGroup == snapshot.majorNodeGroup)
        #expect(loaded.ipResources.count == 1)
        #expect(loaded.excludedIPs == ["127.0.0.1"])
    }

    @Test func loginCallbackPolicyValidatesCASAndOAuth2() throws {
        let casPolicy = NulConnectWebLoginCapturePolicy.cas(baseHost: "ivpn.hit.edu.cn")
        let casURL = URL(string: "https://ids-hit-edu-cn-s.ivpn.hit.edu.cn/passport/v1/auth/cas?ticket=abc123")!
        #expect(casPolicy.shouldCapture(casURL))
        let normalizedCASURL = try casPolicy.validate(casURL)
        #expect(normalizedCASURL.host == "ivpn.hit.edu.cn")
        #expect(normalizedCASURL.query?.contains("ticket=abc123") == true)

        let oauthPolicy = NulConnectWebLoginCapturePolicy.httpsOauth2(baseHost: "ivpn.hit.edu.cn")
        let oauthURL = URL(string: "https://ivpn.hit.edu.cn/passport/v1/auth/httpsOauth2?code=code123&state=null")!
        #expect(oauthPolicy.shouldCapture(oauthURL))
        let normalizedOAuthURL = try oauthPolicy.validate(oauthURL)
        #expect(normalizedOAuthURL.absoluteString.contains("code=code123"))
    }

    @Test func dnsResolverUsesStaticSnapshotRecordsBeforeNetwork() async throws {
        let resolver = NulConnectDNSResolver(resource: dnsTestSnapshot())

        let resolution = try await resolver.resolveARecords(for: "WWW.CNKI.NET.")

        #expect(resolution.domain == "www.cnki.net")
        #expect(resolution.ipv4Addresses == ["10.160.22.90"])
        #expect(resolution.source == .snapshot)
        #expect(resolution.isManagedDomain)

        let route = await resolver.cachedRoute(for: "10.160.22.90")
        #expect(route?.isManaged == true)
        #expect(route?.sourceDomain == "www.cnki.net")
    }

    @Test func dnsResolverClassifiesManagedDomainPatterns() {
        let resolver = NulConnectDNSResolver(resource: dnsTestSnapshot())

        #expect(resolver.isManagedDomain("www.cnki.net"))
        #expect(resolver.isManagedDomain("sub.cnki.net"))
        #expect(resolver.isManagedDomain("i.hit.edu.cn"))
        #expect(!resolver.isManagedDomain("example.com"))
    }

    @Test func dnsResolverClassifiesManagedIPRanges() {
        let resolver = NulConnectDNSResolver(resource: dnsTestSnapshot())

        #expect(resolver.isManagedIPAddress("10.160.22.90"))
        #expect(resolver.isManagedIPAddress("10.160.22.91"))
        #expect(!resolver.isManagedIPAddress("8.8.8.8"))
    }

    private func dnsTestSnapshot() -> ATRResourceSnapshot {
        ATRResourceSnapshot(
            resourceBytes: Data([0x01]),
            dnsServer: "10.254.253.229",
            majorNodeGroup: "group",
            ipResources: [
                ATRIPResource(
                    ipMin: "10.160.22.1",
                    ipMax: "10.160.22.254",
                    portMin: 1,
                    portMax: 65535,
                    protocolName: "all",
                    appID: "ip-app",
                    nodeGroupID: "group"
                )
            ],
            domainResources: [
                ATRDomainResource(
                    domain: ".cnki.net",
                    portMin: 1,
                    portMax: 65535,
                    protocolName: "tcp",
                    appID: "domain-app",
                    nodeGroupID: "group"
                ),
                ATRDomainResource(
                    domain: "i.hit.edu.cn",
                    portMin: 0,
                    portMax: 0,
                    protocolName: "icmp",
                    appID: "icmp-app",
                    nodeGroupID: "group"
                )
            ],
            dnsResources: [
                ATRDNSResource(domain: "www.cnki.net", ip: "10.160.22.90")
            ],
            nodeGroups: [
                ATRNodeGroup(groupID: "group", addresses: ["202.118.253.228:441"])
            ],
            excludedIPs: []
        )
    }

}
