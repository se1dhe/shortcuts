import Foundation

extension WorkspaceModel {
    /// Runs while the app is open; measurements survive restarts. No account
    /// permissions, post changes or upload retries are part of this monitor.
    func monitorChannelPerformance() async {
        guard NSClassFromString("XCTestCase") == nil else { return }
        while !Task.isCancelled {
            await refreshChannelPerformance()
            do { try await Task.sleep(for: .seconds(6 * 3600)) }
            catch { return }
        }
    }

    func refreshChannelPerformance(force: Bool = false) async {
        guard !isRefreshingChannelPerformance else { return }
        isRefreshingChannelPerformance = true
        defer { isRefreshingChannelPerformance = false }
        do {
            channelPerformance = try await ChannelPerformanceService.shared.cached()
            var projects = Array(try await filmProjectService.listRecentProjects().prefix(20))
            if let currentProject {
                projects.removeAll { $0.id == currentProject.id }
                projects.insert(currentProject, at: 0)
            }
            var known = Set<String>()
            let targets = projects.flatMap(ChannelPerformance.targets).filter { known.insert($0.id).inserted }
            channelPerformance = try await ChannelPerformanceService.shared.refresh(targets: targets, force: force)
            channelPerformanceIssue = nil
        } catch is CancellationError { return }
        catch { channelPerformanceIssue = "Не удалось обновить статистику. Сохранённые замеры не изменены." }
    }
}
